import Foundation
import Observation
import DSHKit

/// 一条已建立的数据通道连接（descriptor + transport）。
public struct DSHConnectionHandle: Sendable {
    public let descriptor: BridgeDescriptor
    public let transport: any DSHTransport

    public init(descriptor: BridgeDescriptor, transport: any DSHTransport) {
        self.descriptor = descriptor
        self.transport = transport
    }
}

/// 怎么拿到连接。生产实现读 `bridge.json`，测试实现给假 transport。
public protocol DSHConnectionProvider: Sendable {
    func connect() throws -> DSHConnectionHandle
}

/// 生产实现：`$DSH_HOME/studio/bridge.json` → loopback `URLSession`。
public struct LoopbackConnectionProvider: DSHConnectionProvider {
    private let loader: BridgeDescriptorLoader

    public init(loader: BridgeDescriptorLoader = BridgeDescriptorLoader()) {
        self.loader = loader
    }

    public func connect() throws -> DSHConnectionHandle {
        let descriptor = try loader.load()
        return DSHConnectionHandle(
            descriptor: descriptor,
            transport: URLSessionTransport(baseURL: descriptor.baseURL)
        )
    }
}

public enum DSHClientError: Error, Hashable, Sendable, CustomStringConvertible {
    case descriptor(BridgeDescriptorError)
    /// token 缺失或错误（401/403）。
    case unauthorized
    case httpStatus(Int)
    case malformedResponse(String)
    /// 试图把非官方方法塞进 `/rpc` 转发面（bridge-contract.md §2.2）。
    case nonForwardableMethod(String)

    public var description: String {
        switch self {
        case .descriptor(let error): error.description
        case .unauthorized: "bridge rejected our bearer token"
        case .httpStatus(let status): "bridge answered HTTP \(status)"
        case .malformedResponse(let detail): "bridge answered something unparsable: \(detail)"
        case .nonForwardableMethod(let method):
            "`\(method)` is not an official RpcMethodMap method; studio-owned calls must use /studio/*"
        }
    }

    var disconnectReason: DisconnectReason {
        switch self {
        case .descriptor(let error):
            switch error {
            case .notFound(let path): .runtimeNotRunning(path)
            case .missingToken: .unauthorized
            case .nonLoopbackHost, .insecurePermissions: .insecureDescriptor(error.description)
            default: .transport(error.description)
            }
        case .unauthorized: .unauthorized
        case .httpStatus(let status): .transport("HTTP \(status)")
        case .malformedResponse(let detail): .transport(detail)
        case .nonForwardableMethod(let method): .transport("bad method \(method)")
        }
    }
}

/// 数据通道客户端 —— 领域数据的唯一来源。
///
/// **ADR-0002 的原生侧执行点。** 整个 DSHClient target 里不存在「官方 UI 壳」
/// 这个概念：不 import 任何浏览器框架、不认识插槽、不认识注入面。判据是
/// 「这条数据在官方 UI 壳被删除之后还需要吗？需要 → 走这里」。W8 拆掉壳时，
/// 本 target 一行不动。
///
/// 该约束由 `DSHClientTests/ArchitectureGuardTests.swift` 的源码扫描守护。
@MainActor
@Observable
public final class DSHClient {
    // MARK: 投影缓存（以 seq 为序，不做第二份权威记录）

    public private(set) var link: RuntimeLinkState = .idle
    public private(set) var workspaces: [WorkspaceView] = []
    public private(set) var sessionsByID: [SessionID: SessionSummary] = [:]
    public private(set) var archivedSessionIDs: Set<SessionID> = []
    /// SSE 游标（= `seq`）。
    public private(set) var lastEventID: String?
    /// 每会话已见的最大事件 seq。
    public private(set) var lastSeqBySession: [SessionID: Int] = [:]
    /// 每会话每投影 key 的 watermark（higher-seq-wins）。
    public private(set) var projectionSeq: [SessionID: [String: Int]] = [:]
    /// 全量快照拉取次数（测试与遥测都要看它）。
    public private(set) var snapshotLoadCount = 0
    public private(set) var appliedFrameCount = 0
    /// 未识别的帧名 —— 上游漂移的证据，不静默丢弃。
    public private(set) var unknownFrames: [String] = []
    public private(set) var lastAgentError: String?

    // MARK: 依赖

    private let provider: any DSHConnectionProvider
    private let policy: ResumePolicy
    private let now: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    @ObservationIgnored private var handle: DSHConnectionHandle?
    @ObservationIgnored private var disconnectedAt: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(
        provider: any DSHConnectionProvider = LoopbackConnectionProvider(),
        policy: ResumePolicy = ResumePolicy(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.provider = provider
        self.policy = policy
        self.now = now
        self.sleeper = sleeper
    }

    deinit {
        loop?.cancel()
    }

    // MARK: 生命周期

    /// 后台常驻：连接 → 消费事件流 → 断了退避重连。
    public func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            var attempt = 0
            while let self, !Task.isCancelled {
                let retry = await self.runOnce()
                guard retry, !Task.isCancelled else { break }
                attempt += 1
                try? await self.sleeper(self.policy.backoff(attempt: attempt))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 一次「连接 + 消费到流结束」。返回值表示重试是否有意义。
    ///
    /// 单独暴露是为了让测试不必和后台循环赛跑。
    @discardableResult
    public func runOnce() async -> Bool {
        link = .connecting
        do {
            let handle = try resolveHandle()
            try await consumeEvents(handle: handle)
            markDisconnected(.streamEnded)
            return true
        } catch let error as DSHClientError {
            markDisconnected(error.disconnectReason)
            return error.disconnectReason.isRetryable
        } catch is CancellationError {
            markDisconnected(.cancelled)
            return false
        } catch {
            markDisconnected(.transport(String(describing: error)))
            return true
        }
    }

    // MARK: RPC（POST /rpc）

    /// 转发一次官方 RPC。
    public func rpcValue(_ method: RPCMethod, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard method.isForwardable else {
            throw DSHClientError.nonForwardableMethod(method.rawValue)
        }
        let handle = try resolveHandle()
        return try await rpcValue(method, params: params, handle: handle)
    }

    private func rpcValue(
        _ method: RPCMethod,
        params: JSONValue,
        handle: DSHConnectionHandle
    ) async throws -> JSONValue {
        let body = try JSONValue.object([
            "method": .string(method.rawValue),
            "params": params,
        ]).encoded()
        let reply = try await handle.transport.post(
            path: "/rpc",
            body: body,
            headers: handle.descriptor.authorizationHeaders
        )
        switch reply.status {
        case 200..<300:
            break
        case 401, 403:
            throw DSHClientError.unauthorized
        default:
            throw DSHClientError.httpStatus(reply.status)
        }
        guard let value = try? JSONValue.decode(reply.body) else {
            throw DSHClientError.malformedResponse("/rpc \(method) did not answer JSON")
        }
        return try RPCReply.unwrap(value)
    }

    public func rpc<Value: Decodable>(
        _ method: RPCMethod,
        params: JSONValue = .object([:]),
        as type: Value.Type
    ) async throws -> Value {
        let value = try await rpcValue(method, params: params)
        do {
            return try value.decoded(as: type)
        } catch {
            throw DSHClientError.malformedResponse("\(method): \(error)")
        }
    }

    // MARK: 领域动作（原生视图直接调这些，不经控制通道）

    public func refreshSnapshot() async throws {
        try await refreshSnapshot(handle: try resolveHandle())
    }

    /// 新建会话。
    @discardableResult
    public func createSession(in workspaceID: WorkspaceID? = nil, agentPreset: String? = nil) async throws -> SessionID {
        var params: [String: JSONValue] = [:]
        if let workspaceID { params["workspaceId"] = .string(workspaceID.rawValue) }
        if let agentPreset { params["agentPreset"] = .string(agentPreset) }
        let value = try await rpc(.sessionCreate, params: .object(params), as: SessionCreateValue.self)
        return value.sessionId
    }

    public func archiveSession(_ sessionID: SessionID) async throws {
        let value = try await rpcValue(
            .workspaceArchiveSession,
            params: .object(["sessionId": .string(sessionID.rawValue)])
        )
        if let ids = value["archivedSessionIds"]?.arrayValue {
            archivedSessionIDs = Set(ids.compactMap(\.stringValue).map { SessionID($0) })
        }
    }

    public func renameSession(_ sessionID: SessionID, title: String) async throws {
        _ = try await rpcValue(
            .sessionRename,
            params: .object(["sessionId": .string(sessionID.rawValue), "title": .string(title)])
        )
    }

    // MARK: 快照 + 流

    private func refreshSnapshot(handle: DSHConnectionHandle) async throws {
        let workspaceValue = try await rpcValue(.workspaceList, params: .object([:]), handle: handle)
        let workspaceList = (try? workspaceValue.decoded(as: WorkspaceListValue.self))
            ?? WorkspaceListValue(items: [], archivedSessionIds: [])
        let sessionValue = try await rpcValue(.sessionList, params: .object([:]), handle: handle)
        let sessionList = (try? sessionValue.decoded(as: SessionListValue.self))
            ?? SessionListValue(items: [])

        workspaces = workspaceList.items
        archivedSessionIDs = Set(workspaceList.archivedSessionIds)
        var table: [SessionID: SessionSummary] = [:]
        for summary in sessionList.items {
            table[summary.sessionId] = summary
            if let asOf = summary.projections?.asOfSeq {
                lastSeqBySession[summary.sessionId] = max(lastSeqBySession[summary.sessionId] ?? -1, asOf)
            }
        }
        sessionsByID = table
        snapshotLoadCount += 1
    }

    private func consumeEvents(handle: DSHConnectionHandle) async throws {
        var headers = handle.descriptor.authorizationHeaders
        headers["Accept"] = "text/event-stream"

        let gap = disconnectedAt.map { now().timeIntervalSince($0) } ?? .infinity
        switch policy.plan(lastEventID: lastEventID, disconnectedFor: gap) {
        case .resume(let identifier):
            // 断线续传：`Last-Event-ID` = seq（bridge-contract.md §2.3）。
            headers["Last-Event-ID"] = identifier
        case .fullResync:
            // 断太久 / 首次连接：放弃增量，重拉全量快照再续流。
            link = .resyncing
            lastEventID = nil
            try await refreshSnapshot(handle: handle)
        }

        let (status, chunks) = try await handle.transport.openStream(path: "/events", headers: headers)
        switch status {
        case 200..<300:
            break
        case 401, 403:
            throw DSHClientError.unauthorized
        default:
            throw DSHClientError.httpStatus(status)
        }

        link = .live(since: now())
        disconnectedAt = nil

        var parser = SSEParser()
        for try await chunk in chunks {
            for message in parser.consume(chunk) {
                if let identifier = message.id, !identifier.isEmpty {
                    lastEventID = identifier
                }
                guard let data = try? JSONValue.decode(json: message.data) else {
                    unknownFrames.append("<malformed data for event `\(message.event ?? "message")`>")
                    continue
                }
                apply(StreamFrame.decode(eventName: message.event, data: data))
            }
        }
    }

    /// 把一帧合并进投影缓存。纯状态机，测试直接调它。
    public func apply(_ frame: StreamFrame) {
        appliedFrameCount += 1
        switch frame {
        case .session(let sessionFrame):
            let identifier = sessionFrame.sessionId
            let seq = sessionFrame.event.seq
            // 以 seq 为序：老事件（重放/乱序）不许覆盖新状态。
            guard seq > (lastSeqBySession[identifier] ?? -1) else { return }
            lastSeqBySession[identifier] = seq
            var summary = sessionsByID[identifier] ?? SessionSummary(
                sessionId: identifier,
                updatedAt: sessionFrame.event.time,
                running: false,
                blank: true
            )
            summary.updatedAt = max(summary.updatedAt, sessionFrame.event.time)
            switch sessionFrame.event.payload {
            case .turnStart:
                summary.blank = false
                summary.running = true
            case .turnEnd:
                summary.running = false
            case .userMessage:
                summary.blank = false
            case .assistantMessage, .assistantChunk, .toolCall, .toolResult:
                summary.blank = false
            case .unknown(let value):
                // 上游加了新事件类型：不崩、不猜语义，只记账。
                unknownFrames.append(value["type"]?.stringValue ?? "session/?")
            }
            sessionsByID[identifier] = summary

        case .host(let hostFrame):
            apply(hostFrame)

        case .projection(let projection):
            let previous = projectionSeq[projection.sessionId]?[projection.key] ?? -1
            guard projection.seq >= previous else { return }
            projectionSeq[projection.sessionId, default: [:]][projection.key] = projection.seq
            var summary = sessionsByID[projection.sessionId] ?? SessionSummary(
                sessionId: projection.sessionId,
                updatedAt: 0,
                running: false,
                blank: true
            )
            var block = summary.projections ?? SessionProjections(asOfSeq: -1, values: [:])
            block.values[projection.key] = projection.value
            block.asOfSeq = max(block.asOfSeq, projection.seq)
            summary.projections = block
            sessionsByID[projection.sessionId] = summary

        case .unknown(let name, _):
            unknownFrames.append(name)
        }
    }

    private func apply(_ frame: HostFrame) {
        switch frame {
        case .sessionAdded(let summary):
            var merged = summary
            if let existing = sessionsByID[summary.sessionId] {
                merged.running = existing.running
                merged.projections = existing.projections ?? summary.projections
            }
            sessionsByID[summary.sessionId] = merged
        case .sessionRemoved(let identifier):
            sessionsByID.removeValue(forKey: identifier)
            lastSeqBySession.removeValue(forKey: identifier)
            projectionSeq.removeValue(forKey: identifier)
        case .sessionStatus(let identifier, let running):
            guard var summary = sessionsByID[identifier] else {
                sessionsByID[identifier] = SessionSummary(
                    sessionId: identifier,
                    updatedAt: now().timeIntervalSince1970,
                    running: running,
                    blank: !running
                )
                return
            }
            summary.running = running
            if running { summary.blank = false }
            sessionsByID[identifier] = summary
        case .agentError(_, let message):
            lastAgentError = message
        case .workspaceChanged(let workspace):
            if let index = workspaces.firstIndex(where: { $0.workspaceId == workspace.workspaceId }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
        case .workspaceRemoved(let identifier):
            workspaces.removeAll { $0.workspaceId == identifier }
        case .workspaceOrderChanged(let order):
            let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            workspaces.sort { lhs, rhs in
                (position[lhs.workspaceId] ?? Int.max) < (position[rhs.workspaceId] ?? Int.max)
            }
        case .archivedSessionsChanged(let ids):
            archivedSessionIDs = Set(ids)
        case .unknown(let value):
            unknownFrames.append(value["type"]?.stringValue ?? "host/?")
        }
    }

    // MARK: 侧栏用的读模型

    /// 一个工作区下要显示的会话（保持工作区自己的顺序，隐去归档与空会话）。
    ///
    /// 空会话隐藏是上游语义：*"Clients hide blank Sessions from lists and
    /// reuse them for New Session on the same workspace."*
    public func visibleSessions(in workspace: WorkspaceView) -> [SessionSummary] {
        workspace.sessionIds.compactMap { identifier in
            guard !archivedSessionIDs.contains(identifier) else { return nil }
            guard let summary = sessionsByID[identifier] else { return nil }
            guard !summary.blank else { return nil }
            return summary
        }
    }

    /// 不属于任何工作区的会话（子 agent 会话、cwd 会话）。
    public func looseSessions() -> [SessionSummary] {
        let claimed = Set(workspaces.flatMap(\.sessionIds))
        return sessionsByID.values
            .filter { !claimed.contains($0.sessionId) && !archivedSessionIDs.contains($0.sessionId) && !$0.blank }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public var runningSessionCount: Int {
        sessionsByID.values.count(where: \.running)
    }

    // MARK: 内部

    private func resolveHandle() throws -> DSHConnectionHandle {
        if let handle { return handle }
        do {
            let resolved = try provider.connect()
            handle = resolved
            return resolved
        } catch let error as BridgeDescriptorError {
            throw DSHClientError.descriptor(error)
        }
    }

    private func markDisconnected(_ reason: DisconnectReason) {
        // token 是一次性的：断开后重新读 descriptor，而不是复用旧连接。
        handle = nil
        let timestamp = now()
        disconnectedAt = timestamp
        link = .disconnected(reason: reason, since: timestamp)
    }
}
