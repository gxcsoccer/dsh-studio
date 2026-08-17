import Foundation
import DSHKit

/// Native→Web 的注入面。
///
/// 抽成协议只有一个目的：让控制通道的握手、超时、幂等、拒绝逻辑能在**没有
/// WKWebView**（也没有窗口、没有 run loop）的情况下被无头测试。
@MainActor
public protocol SurfaceScriptEvaluator: AnyObject {
    func evaluate(_ javaScript: String) async throws
}

/// Native→Web 的脚本构造（bridge-contract.md §1.1）。
public enum SurfaceScript {
    /// client 半在 `apply(ctx)` 里用 `ctx.effect()` 挂上的接收面。
    public static let receiver = "window.__DSH_STUDIO__"

    /// `window.__DSH_STUDIO__.receive(<json>)`
    ///
    /// JSON 不做字符串拼接进 JS 表达式，而是 `JSON.parse("<escaped>")`：
    /// 拼接会在遇到 `</script>`、U+2028、引号时产出可执行的垃圾。
    public static func receiveCall(_ envelope: BridgeEnvelope) throws -> String {
        let json = try envelope.jsonText()
        return "(function(){var b=\(receiver);if(!b||typeof b.receive!=='function')"
            + "{throw new Error('__DSH_STUDIO__ receiver missing')};"
            + "return b.receive(JSON.parse(\(jsStringLiteral(json))))})()"
    }

    /// 把任意文本编码成一个安全的 JS 双引号字符串字面量。
    public static func jsStringLiteral(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value > 0x7E
                    || scalar == "<" || scalar == ">" {
                    // 非 ASCII 与行分隔符一律 \uXXXX：JS 源里的裸 U+2028 是语法错误。
                    // `<` / `>` 也转义：这样这段脚本即使被塞进 HTML 也不会提前闭合 `</script>`。
                    for unit in String(scalar).utf16 {
                        out += String(format: "\\u%04X", unit)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// 控制通道：**只搬运插槽编排**（ARCHITECTURE.md §6.1）。
///
/// - Web→Native：`window.webkit.messageHandlers.studio.postMessage(<json>)`
/// - Native→Web：`webView.evaluateJavaScript("window.__DSH_STUDIO__.receive(…)")`
///
/// 这里刻意不认识会话、事件、工作区。任何领域实体想从这里过 → ADR-0002 违规。
@MainActor
public final class ControlChannel: SlotInvocationSink {
    /// `WKScriptMessageHandler` 注册的名字。
    public static let messageHandlerName = "studio"

    /// 插槽编排事件（`slot/*`）。抛错表示装配被拒（例如 ADR-0003 违规）。
    public var onSlotEvent: (@MainActor (SurfaceEvent) throws -> Void)?
    /// 握手（`surface/ready`）。
    public var onReady: (@MainActor (SurfaceReady) -> Void)?
    /// 协议版本不一致 —— 不猜、不适配，交给协调器降级（bridge-contract.md §4）。
    public var onProtocolMismatch: (@MainActor (Int) -> Void)?

    private weak var evaluator: (any SurfaceScriptEvaluator)?
    private let telemetry: any SurfaceTelemetry
    private let sleeper: @Sendable (Duration) async throws -> Void

    private var pending: [MessageID: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeouts: [MessageID: Task<Void, Never>] = [:]

    // 记账
    public private(set) var sentRequestCount = 0
    public private(set) var rejectedInputCount = 0
    public private(set) var lastRejection: String?

    public init(
        telemetry: any SurfaceTelemetry = LoggingSurfaceTelemetry(),
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.telemetry = telemetry
        self.sleeper = sleeper
    }

    public func attach(evaluator: any SurfaceScriptEvaluator) {
        self.evaluator = evaluator
    }

    public func detachEvaluator() {
        evaluator = nil
        failAllPending(ControlChannelError.webViewUnavailable)
    }

    // MARK: Native → Web

    /// 发一个 `req` 并等回执。
    ///
    /// 超时 5s（`surface/configure` 15s），**不重试** —— 重试编排会造成重复
    /// 挂载（bridge-contract.md §1.5）。
    @discardableResult
    public func request(
        _ method: String,
        payload: JSONValue = .object([:]),
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        guard let evaluator else { throw ControlChannelError.webViewUnavailable }
        let identifier = ULID.generate()
        let envelope = BridgeEnvelope.request(id: identifier, method: method, payload: payload)
        let script = try SurfaceScript.receiveCall(envelope)
        let deadline = timeout ?? ControlMethod.timeout(for: method)
        sentRequestCount += 1

        return try await withCheckedThrowingContinuation { continuation in
            // 先登记再发送：否则回执可能早于登记到达。
            pending[identifier] = continuation
            timeouts[identifier] = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.sleeper(deadline)
                guard !Task.isCancelled else { return }
                self.settle(
                    identifier,
                    with: .failure(ControlChannelError.timedOut(method: method, after: deadline))
                )
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await evaluator.evaluate(script)
                } catch {
                    self.settle(
                        identifier,
                        with: .failure(ControlChannelError.evaluationFailed(String(describing: error)))
                    )
                }
            }
        }
    }

    /// 单向 `evt`（Native→Web 目前契约里没有，保留给诊断）。
    public func emit(_ method: String, payload: JSONValue = .object([:])) async throws {
        guard let evaluator else { throw ControlChannelError.webViewUnavailable }
        try await evaluator.evaluate(try SurfaceScript.receiveCall(.event(method: method, payload: payload)))
    }

    /// `slot/invoke`：原生视图上的用户动作回灌 Web 侧注入面。
    @discardableResult
    public func invoke(
        slot: String,
        instanceID: String,
        action: String,
        args: [JSONValue]
    ) async throws -> JSONValue {
        try await request(ControlMethod.slotInvoke, payload: .object([
            "slot": .string(slot),
            "instanceId": .string(instanceID),
            "action": .string(action),
            "args": .array(args),
        ]))
    }

    // MARK: Web → Native

    /// 处理 `WKScriptMessage.body`。
    ///
    /// bridge-contract.md §5：来自 WebView 的消息**一律当不可信输入**校验
    /// —— WebView 里同时跑着官方与第三方 client 插件，对端不是自己人。
    public func receive(rawBody: Any) {
        if let text = rawBody as? String {
            receive(text: text)
            return
        }
        // WKWebView 会把 JS 对象转成 NSDictionary/NSArray；重新序列化后走同一条校验路径。
        if JSONSerialization.isValidJSONObject(rawBody),
           let data = try? JSONSerialization.data(withJSONObject: rawBody),
           let text = String(data: data, encoding: .utf8) {
            receive(text: text)
            return
        }
        reject(BridgeFault(code: .badPayload, message: "control message body is neither JSON text nor a JSON object"), raw: "")
    }

    public func receive(text: String) {
        guard text.utf8.count <= SurfaceInputLimits.maxMessageBytes else {
            reject(
                BridgeFault(code: .badPayload, message: "control message exceeds \(SurfaceInputLimits.maxMessageBytes) bytes"),
                raw: ""
            )
            return
        }
        let envelope: BridgeEnvelope
        do {
            envelope = try BridgeEnvelope.decode(json: text)
        } catch BridgeDecodingError.unsupportedProtocolVersion(let version) {
            // 未知协议版本 → 拒绝，不猜。降级决策交给协调器。
            reject(BridgeFault(code: .protocolMismatch, message: "peer protocol v\(version)"), raw: text)
            onProtocolMismatch?(version)
            return
        } catch {
            reject(BridgeFault(code: .badPayload, message: String(describing: error)), raw: text)
            return
        }
        dispatch(envelope)
    }

    public func receive(envelope: BridgeEnvelope) {
        dispatch(envelope)
    }

    private func dispatch(_ envelope: BridgeEnvelope) {
        switch envelope {
        case .success(let identifier, let payload):
            settle(identifier, with: .success(payload))

        case .failure(let identifier, let fault):
            settle(identifier, with: .failure(fault))

        case .event(let method, let payload):
            handleEvent(method: method, payload: payload)

        case .request(let identifier, let method, _):
            // 契约里没有 Web→Native 的 req。回一个封闭错误码，不静默。
            reject(BridgeFault(code: .unknownMethod, message: "web side sent req `\(method)`"), raw: "")
            Task { @MainActor [weak self] in
                guard let self, let evaluator = self.evaluator else { return }
                let reply = BridgeEnvelope.failure(
                    id: identifier,
                    error: BridgeFault(code: .unknownMethod, message: "host accepts no requests", retryable: false)
                )
                if let script = try? SurfaceScript.receiveCall(reply) {
                    try? await evaluator.evaluate(script)
                }
            }
        }
    }

    private func handleEvent(method: String, payload: JSONValue) {
        if method == ControlMethod.surfaceReady {
            do {
                let ready = try SurfaceEventDecoder.decodeReady(payload)
                onReady?(ready)
            } catch let fault as BridgeFault {
                reject(fault, raw: "")
            } catch {
                reject(BridgeFault(code: .badPayload, message: String(describing: error)), raw: "")
            }
            return
        }
        do {
            let event = try SurfaceEventDecoder.decode(method: method, payload: payload)
            try onSlotEvent?(event)
        } catch let fault as BridgeFault {
            reject(fault, raw: "")
        } catch let error as SurfaceError {
            // 装配被拒（ADR-0003 等）。host 已经上报过，这里只记账。
            rejectedInputCount += 1
            lastRejection = error.description
        } catch {
            reject(BridgeFault(code: .internalError, message: String(describing: error)), raw: "")
        }
    }

    // MARK: 内部

    private func settle(_ identifier: MessageID, with result: Result<JSONValue, any Error>) {
        timeouts.removeValue(forKey: identifier)?.cancel()
        guard let continuation = pending.removeValue(forKey: identifier) else { return }
        continuation.resume(with: result)
    }

    private func failAllPending(_ error: any Error) {
        let ids = Array(pending.keys)
        for identifier in ids {
            settle(identifier, with: .failure(error))
        }
    }

    private func reject(_ fault: BridgeFault, raw: String) {
        rejectedInputCount += 1
        lastRejection = fault.description
        telemetry.inputRejected(fault, raw: raw)
    }
}
