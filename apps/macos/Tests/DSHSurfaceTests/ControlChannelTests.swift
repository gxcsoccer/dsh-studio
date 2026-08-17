import Testing
import Foundation
import SwiftUI
@testable import DSHKit
@testable import DSHSurface

/// 假注入面（Native→Web）。
///
/// 存在意义：控制通道的握手 / 超时 / 拒绝逻辑全部可以在**没有 WKWebView、
/// 没有窗口、没有 run loop** 的情况下断言。
@MainActor
final class FakeEvaluator: SurfaceScriptEvaluator {
    var scripts: [String] = []
    var failure: (any Error)?
    /// 收到脚本后自动回执（模拟 Web 侧的 client 半）。
    var autoReply: (@MainActor (BridgeEnvelope) -> BridgeEnvelope?)?
    weak var channel: ControlChannel?

    func evaluate(_ javaScript: String) async throws {
        scripts.append(javaScript)
        if let failure { throw failure }
        guard let autoReply, let channel, let envelope = decodeRequest(javaScript) else { return }
        if let reply = autoReply(envelope) {
            channel.receive(envelope: reply)
        }
    }

    /// 从 `window.__DSH_STUDIO__.receive(JSON.parse("…"))` 里把信封抠回来。
    /// 顺带验证了脚本确实是「JSON.parse 一个字符串字面量」而不是拼接出来的表达式。
    func decodeRequest(_ script: String) -> BridgeEnvelope? {
        guard let start = script.range(of: "JSON.parse(\""),
              let end = script.range(of: "\"))", range: start.upperBound..<script.endIndex) else { return nil }
        let literal = String(script[start.upperBound..<end.lowerBound])
        let unescaped = "\"\(literal)\""
        guard let data = unescaped.data(using: .utf8),
              let text = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        return try? BridgeEnvelope.decode(json: text)
    }

    var lastRequest: BridgeEnvelope? {
        scripts.last.flatMap(decodeRequest)
    }
}

@MainActor
private func makeChannel(
    telemetry: RecordingTelemetry = RecordingTelemetry(),
    sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) -> (channel: ControlChannel, evaluator: FakeEvaluator, telemetry: RecordingTelemetry) {
    let channel = ControlChannel(telemetry: telemetry, sleeper: sleeper)
    let evaluator = FakeEvaluator()
    evaluator.channel = channel
    channel.attach(evaluator: evaluator)
    return (channel, evaluator, telemetry)
}

@Suite("ControlChannel：请求/回执/超时/不可信输入")
@MainActor
struct ControlChannelTests {
    @Test("req 送出的脚本走 JSON.parse，不是字符串拼接")
    func requestScriptIsSafe() async throws {
        let (channel, evaluator, _) = makeChannel()
        evaluator.autoReply = { envelope in
            guard let id = envelope.id else { return nil }
            return .success(id: id, payload: .object(["applied": .array([.string("sidebar.workspaces")])]))
        }
        let reply = try await channel.request(ControlMethod.surfaceConfigure, payload: .object([
            "manifest": .object(["sidebar.workspaces": .object(["mode": .string("native")])]),
            // 危险字符：拼接实现会在这里生成可执行垃圾。
            "note": .string("</script>\u{2028}\"'\\ 中文"),
        ]))
        #expect(reply["applied"]?.arrayValue?.count == 1)

        let script = try #require(evaluator.scripts.first)
        #expect(script.contains("window.__DSH_STUDIO__"))
        #expect(script.contains("JSON.parse("))
        #expect(!script.contains("</script>"))
        #expect(!script.unicodeScalars.contains { $0.value == 0x2028 })

        let request = try #require(evaluator.lastRequest)
        #expect(request.method == ControlMethod.surfaceConfigure)
        #expect(request.payload["note"]?.stringValue == "</script>\u{2028}\"'\\ 中文")
    }

    @Test("res ok:false 变成 Swift 侧的抛错，不可能被忽略")
    func failureRepliesThrow() async throws {
        let (channel, evaluator, _) = makeChannel()
        evaluator.autoReply = { envelope in
            guard let id = envelope.id else { return nil }
            return .failure(id: id, error: BridgeFault(code: .priorityConflict, message: "ui-workspace at priority 0"))
        }
        await #expect(throws: BridgeFault(code: .priorityConflict, message: "ui-workspace at priority 0")) {
            _ = try await channel.request(ControlMethod.surfaceConfigure)
        }
    }

    @Test("超时后不重试：只发一次脚本（重放编排会重复挂载）")
    func timesOutWithoutRetrying() async throws {
        // 注入即时 sleeper：不真的等 5s。
        let (channel, evaluator, _) = makeChannel(sleeper: { _ in })
        await #expect(throws: ControlChannelError.timedOut(method: ControlMethod.slotInvoke, after: .seconds(5))) {
            _ = try await channel.request(ControlMethod.slotInvoke, payload: .object([:]))
        }
        #expect(evaluator.scripts.count == 1)
        #expect(channel.sentRequestCount == 1)
    }

    @Test("超时时长表：默认 5s，surface/configure 15s")
    func timeoutBudgets() async throws {
        // evaluator 必须被持有：ControlChannel 只弱引用它。
        let (channel, evaluator, _) = makeChannel(sleeper: { _ in })
        await #expect(throws: ControlChannelError.timedOut(method: ControlMethod.surfaceConfigure, after: .seconds(15))) {
            _ = try await channel.request(ControlMethod.surfaceConfigure)
        }
        #expect(evaluator.scripts.count == 1)
    }

    @Test("注入面不可用时立刻失败，不静默排队")
    func failsWithoutEvaluator() async throws {
        let channel = ControlChannel()
        await #expect(throws: ControlChannelError.webViewUnavailable) {
            _ = try await channel.request(ControlMethod.slotProbe)
        }
    }

    @Test("evaluateJavaScript 抛错 → 请求立刻失败")
    func propagatesEvaluationFailure() async throws {
        let (channel, evaluator, _) = makeChannel(sleeper: { _ in try await Task.sleep(for: .seconds(30)) })
        struct Boom: Error {}
        evaluator.failure = Boom()
        await #expect(throws: (any Error).self) {
            _ = try await channel.request(ControlMethod.slotProbe)
        }
    }

    @Test("不可信输入：垃圾文本、超大消息、未知 t 一律被拒并记账")
    func rejectsUntrustedInput() {
        let (channel, _, telemetry) = makeChannel()
        channel.receive(text: "not json at all")
        channel.receive(text: #"{"v":1,"t":"nope"}"#)
        channel.receive(text: #"{"v":1,"t":"evt"}"#) // 缺 m
        channel.receive(rawBody: Data([0x00, 0x01]))
        let oversized = #"{"v":1,"t":"evt","m":"slot/props","p":{"x":""# + String(repeating: "a", count: 300_000) + #""}}"#
        channel.receive(text: oversized)

        #expect(channel.rejectedInputCount == 5)
        #expect(telemetry.faults.count == 5)
        #expect(telemetry.faults.allSatisfy { $0.code == .badPayload })
    }

    @Test("未知协议版本 → 拒绝 + 通知协调器（不猜、不适配）")
    func reportsProtocolMismatch() {
        let (channel, _, telemetry) = makeChannel()
        var reported: [Int] = []
        channel.onProtocolMismatch = { reported.append($0) }
        channel.receive(text: #"{"v":99,"t":"evt","m":"surface/ready","p":{"protocol":99}}"#)
        #expect(reported == [99])
        #expect(telemetry.faults.first?.code == .protocolMismatch)
    }

    @Test("Web→Native 的 req 被回一个封闭错误码，不静默")
    func refusesWebInitiatedRequests() throws {
        let (channel, evaluator, telemetry) = makeChannel()
        channel.receive(text: #"{"v":1,"t":"req","id":"01J000000000000000000000AB","m":"host/openFile","p":{}}"#)
        #expect(telemetry.faults.first?.code == .unknownMethod)
        #expect(channel.rejectedInputCount == 1)
        _ = evaluator // 回执是异步发的，这里只断言拒绝已记账
    }

    @Test("evt 的字典 body（WKWebView 会给 NSDictionary）走同一条校验路径")
    func acceptsDictionaryBody() throws {
        let (channel, _, _) = makeChannel()
        var seen: [SurfaceEvent] = []
        channel.onSlotEvent = { seen.append($0) }
        channel.receive(rawBody: [
            "v": 1,
            "t": "evt",
            "m": "slot/mount",
            "p": ["slot": "sidebar.workspaces", "instanceId": "inst-1", "scope": "root"],
        ] as [String: Any])
        #expect(seen.count == 1)
        #expect(seen.first?.instanceID == "inst-1")
    }

    @Test("装配被拒（ADR-0003）在通道层只记账，不再往 Web 侧回 fault 风暴")
    func recordsAssemblyRejection() {
        let (channel, _, telemetry) = makeChannel()
        channel.onSlotEvent = { _ in
            throw SurfaceError.overlayInsideScrollContainer(slot: W1.workspacesSlot, instanceID: "inst-1")
        }
        channel.receive(text: #"{"v":1,"t":"evt","m":"slot/rect","p":{"instanceId":"inst-1","rect":{"x":0,"y":0,"w":10,"h":10},"scrollable":true}}"#)
        #expect(channel.rejectedInputCount == 1)
        #expect(channel.lastRejection?.contains("ADR-0003") == true)
        #expect(telemetry.faults.isEmpty)
    }

    @Test("JS 字符串字面量转义：所有非 ASCII 与行分隔符都编码成 \\uXXXX")
    func escapesJSLiterals() {
        #expect(SurfaceScript.jsStringLiteral("a\"b") == #""a\"b""#)
        #expect(SurfaceScript.jsStringLiteral("a\\b") == #""a\\b""#)
        #expect(SurfaceScript.jsStringLiteral("\n") == #""\n""#)
        #expect(SurfaceScript.jsStringLiteral("\u{2028}") == #""\u2028""#)
        #expect(SurfaceScript.jsStringLiteral("中") == #""\u4E2D""#)
        #expect(SurfaceScript.jsStringLiteral("</script>") == #""\u003C/script\u003E""#)
    }
}

@Suite("SurfaceCoordinator：握手窗口、降级、热切换")
@MainActor
struct SurfaceCoordinatorTests {
    private func makeStack(
        manifest: SurfaceManifest = .w1Default,
        handshakeTimeout: Duration = .seconds(15),
        registerWorkspaces: Bool = true,
        channelSleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        coordinatorSleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> (coordinator: SurfaceCoordinator, channel: ControlChannel, evaluator: FakeEvaluator, host: NativeSlotHost, telemetry: RecordingTelemetry) {
        let telemetry = RecordingTelemetry()
        let (channel, evaluator, _) = makeChannel(telemetry: telemetry, sleeper: channelSleeper)
        let (host, _, _) = makeHost(manifest: manifest, telemetry: telemetry, registerWorkspaces: registerWorkspaces)
        let coordinator = SurfaceCoordinator(
            channel: channel,
            host: host,
            manifest: manifest,
            telemetry: telemetry,
            handshakeTimeout: handshakeTimeout,
            sleeper: coordinatorSleeper
        )
        return (coordinator, channel, evaluator, host, telemetry)
    }

    /// 契约里的握手窗口就是 15s —— 这个数字被钉在测试里，改它必须改契约文档。
    @Test("握手窗口默认 15s（bridge-contract.md §1.1）")
    func handshakeWindowIsFifteenSeconds() {
        #expect(SurfaceCoordinator.handshakeWindow == .seconds(15))
    }

    @Test("握手前一个原生插槽都不渲染")
    func rendersNothingBeforeHandshake() throws {
        let stack = makeStack()
        try stack.coordinator.start()
        #expect(stack.coordinator.phase == .launching)
        #expect(stack.coordinator.phase.rendersNativeSlots == false)
        stack.coordinator.stop()
    }

    @Test("15s 内没有 surface/ready → 降级为纯官方 Web UI 并上报")
    func degradesOnHandshakeTimeout() async throws {
        // 用一个「立刻返回」的 sleeper 顶替 15s，语义不变、测试不睡。
        let stack = makeStack(handshakeTimeout: .seconds(15), coordinatorSleeper: { _ in })
        try stack.coordinator.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(stack.coordinator.phase == .degradedWebOnly(.handshakeTimeout(.seconds(15))))
        #expect(stack.telemetry.degradations == [.handshakeTimeout(.seconds(15))])
        #expect(stack.coordinator.phase.rendersNativeSlots == false)
    }

    @Test("握手成功 → 下发 manifest → live，原生插槽才允许渲染")
    func goesLiveAfterConfigure() async throws {
        let stack = makeStack()
        stack.evaluator.autoReply = { envelope in
            guard let id = envelope.id, envelope.method == ControlMethod.surfaceConfigure else { return nil }
            return .success(id: id, payload: .object([
                "applied": .array([.string(W1.workspacesSlot)]),
                "rejected": .array([]),
            ]))
        }
        try stack.coordinator.start()
        stack.channel.receive(envelope: .event(method: ControlMethod.surfaceReady, payload: .object([
            "protocol": .number(1),
            "slots": .array([
                .object(["name": .string("sidebar"), "kind": .string("single"), "scope": .string("root")]),
                .object(["name": .string(W1.workspacesSlot), "kind": .string("single"), "scope": .string("root")]),
            ]),
        ])))
        try await Task.sleep(for: .milliseconds(50))

        #expect(stack.coordinator.phase == .live(protocolVersion: 1))
        #expect(stack.coordinator.phase.rendersNativeSlots)
        #expect(stack.coordinator.lastConfigureResult?.applied == [W1.workspacesSlot])
        #expect(stack.coordinator.drift == nil)
        #expect(stack.telemetry.degradations.isEmpty)

        // live 之后编排事件才被真正处理。
        stack.channel.receive(envelope: .event(method: ControlMethod.slotMount, payload: .object([
            "slot": .string(W1.workspacesSlot),
            "instanceId": .string("inst-1"),
            "scope": .string("root"),
            "actions": .array([.string("startSession")]),
        ])))
        #expect(stack.host.stage.visibleInstance(of: W1.workspacesSlot) != nil)
    }

    @Test("surface/ready 里的协议版本不一致 → 降级，不适配")
    func degradesOnProtocolMismatch() async throws {
        let stack = makeStack()
        try stack.coordinator.start()
        stack.channel.receive(envelope: .event(method: ControlMethod.surfaceReady, payload: .object([
            "protocol": .number(7),
            "slots": .array([]),
        ])))
        #expect(stack.coordinator.phase == .degradedWebOnly(.protocolMismatch(peer: 7)))
    }

    @Test("configure 超时 → 降级（不是无限等）")
    func degradesWhenConfigureTimesOut() async throws {
        let stack = makeStack(channelSleeper: { _ in })
        try stack.coordinator.start()
        stack.channel.receive(envelope: .event(method: ControlMethod.surfaceReady, payload: .object([
            "protocol": .number(1),
            "slots": .array([.object(["name": .string(W1.workspacesSlot), "kind": .string("single"), "scope": .string("root")])]),
        ])))
        try await Task.sleep(for: .milliseconds(50))
        guard case .degradedWebOnly(.configureFailed) = stack.coordinator.phase else {
            Issue.record("expected configureFailed degradation, got \(stack.coordinator.phase)")
            return
        }
    }

    @Test("我们要接管的每一格都被拒 → 老实降级")
    func degradesWhenEverythingRejected() async throws {
        let stack = makeStack()
        stack.evaluator.autoReply = { envelope in
            guard let id = envelope.id, envelope.method == ControlMethod.surfaceConfigure else { return nil }
            return .success(id: id, payload: .object([
                "applied": .array([]),
                "rejected": .array([.object(["slot": .string(W1.workspacesSlot), "reason": .string("priority_conflict")])]),
            ]))
        }
        try stack.coordinator.start()
        stack.channel.receive(envelope: .event(method: ControlMethod.surfaceReady, payload: .object([
            "protocol": .number(1),
            "slots": .array([.object(["name": .string(W1.workspacesSlot), "kind": .string("single"), "scope": .string("root")])]),
        ])))
        try await Task.sleep(for: .milliseconds(50))
        guard case .degradedWebOnly(.configureFailed(let detail)) = stack.coordinator.phase else {
            Issue.record("expected degradation, got \(stack.coordinator.phase)")
            return
        }
        #expect(detail.contains("priority_conflict"))
    }

    @Test("启动自检：manifest 说要原生但没实现 → start() 直接抛，不等用户看空白")
    func startFailsLoudlyWithoutImplementation() {
        let stack = makeStack(registerWorkspaces: false)
        #expect(throws: SurfaceError.noNativeImplementation(slot: W1.workspacesSlot)) {
            try stack.coordinator.start()
        }
    }

    @Test("实测插槽表漂移：告警但不降级（未列出的插槽本来就落在 web）")
    func reportsDriftWithoutDegrading() async throws {
        let stack = makeStack()
        stack.evaluator.autoReply = { envelope in
            guard let id = envelope.id, envelope.method == ControlMethod.surfaceConfigure else { return nil }
            return .success(id: id, payload: .object(["applied": .array([.string(W1.workspacesSlot)]), "rejected": .array([])]))
        }
        try stack.coordinator.start()
        // 上游把我们要接管的插槽 kind 从 single 改成了 list。
        stack.channel.receive(envelope: .event(method: ControlMethod.surfaceReady, payload: .object([
            "protocol": .number(1),
            "slots": .array([.object(["name": .string(W1.workspacesSlot), "kind": .string("list"), "scope": .string("root")])]),
        ])))
        try await Task.sleep(for: .milliseconds(50))
        #expect(stack.coordinator.drift != nil)
        #expect(stack.telemetry.drifts.count == 1)
        #expect(stack.coordinator.phase == .live(protocolVersion: 1))
    }

    @Test("我们要接管的插槽在上游消失了 → 记为漂移")
    func detectsMissingSlot() {
        let drift = SlotContractSnapshot.w1.drift(
            against: [DeclaredSlot(name: "sidebar", kind: .single, scope: .root)],
            interestedIn: [W1.workspacesSlot]
        )
        #expect(drift?.missing == [W1.workspacesSlot])
    }

    @Test("⌥⇧D：热切 native → web 会清空舞台，切回来要求真有实现")
    func togglesModeAtRuntime() async throws {
        let stack = makeStack()
        stack.evaluator.autoReply = { envelope in
            guard let id = envelope.id else { return nil }
            switch envelope.method {
            case ControlMethod.surfaceConfigure:
                return .success(id: id, payload: .object(["applied": .array([.string(W1.workspacesSlot)]), "rejected": .array([])]))
            case ControlMethod.surfaceReconfigure:
                return .success(id: id, payload: .object(["applied": .array([.string(W1.workspacesSlot)]), "rejected": .array([])]))
            default:
                return nil
            }
        }
        try stack.coordinator.start()
        stack.channel.receive(envelope: .event(method: ControlMethod.surfaceReady, payload: .object([
            "protocol": .number(1),
            "slots": .array([.object(["name": .string(W1.workspacesSlot), "kind": .string("single"), "scope": .string("root")])]),
        ])))
        try await Task.sleep(for: .milliseconds(50))
        stack.channel.receive(envelope: .event(method: ControlMethod.slotMount, payload: .object([
            "slot": .string(W1.workspacesSlot),
            "instanceId": .string("inst-1"),
            "scope": .string("root"),
        ])))
        #expect(stack.host.stage.mounted.count == 1)

        let toWeb = await stack.coordinator.toggleMode(for: W1.workspacesSlot)
        #expect(toWeb == .web)
        #expect(stack.coordinator.manifest.entry(for: W1.workspacesSlot).mode == .web)
        // 不等 Web 侧的 slot/unmount：立刻清舞台，避免热切换留残影。
        #expect(stack.host.stage.mounted.isEmpty)
        let reconfigure = try #require(stack.evaluator.lastRequest)
        #expect(reconfigure.method == ControlMethod.surfaceReconfigure)
        #expect(reconfigure.payload["patch"]?[W1.workspacesSlot]?["mode"]?.stringValue == "web")

        let backToNative = await stack.coordinator.toggleMode(for: W1.workspacesSlot)
        #expect(backToNative == .native)
        #expect(stack.coordinator.manifest.entry(for: W1.workspacesSlot).mode == .native)
    }

    @Test("热切到 native 但没有实现 → 拒绝切换（不把用户切进空白）")
    func refusesToggleWithoutImplementation() async throws {
        let manifest = SurfaceManifest(slots: [W1.workspacesSlot: SlotEntry(mode: .web)])
        let stack = makeStack(manifest: manifest, registerWorkspaces: false)
        try stack.coordinator.start()
        let result = await stack.coordinator.toggleMode(for: W1.workspacesSlot)
        #expect(result == nil)
        #expect(stack.coordinator.manifest.entry(for: W1.workspacesSlot).mode == .web)
    }

    @Test("降级之后仍到达的编排事件被安全丢弃")
    func dropsOrchestrationAfterDegrading() async throws {
        let stack = makeStack(handshakeTimeout: .milliseconds(1), coordinatorSleeper: { _ in })
        try stack.coordinator.start()
        try await Task.sleep(for: .milliseconds(50))
        stack.channel.receive(envelope: .event(method: ControlMethod.slotMount, payload: .object([
            "slot": .string(W1.workspacesSlot),
            "instanceId": .string("inst-1"),
            "scope": .string("root"),
        ])))
        #expect(stack.host.stage.mounted.isEmpty)
        #expect(stack.telemetry.drops.contains { $0.contains("phase=") })
    }
}
