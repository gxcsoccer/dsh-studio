import Foundation
import Observation
import os
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
    /// 事件流自己报错（mux `stream/error`）：上游说流坏了，不是我们读不懂。
    case streamFaulted(String)

    public var description: String {
        switch self {
        case .descriptor(let error): error.description
        case .unauthorized: "bridge rejected our bearer token"
        case .httpStatus(let status): "bridge answered HTTP \(status)"
        case .malformedResponse(let detail): "bridge answered something unparsable: \(detail)"
        case .nonForwardableMethod(let method):
            "`\(method)` is not an official RpcMethodMap method; studio-owned calls must use /studio/*"
        case .streamFaulted(let detail): "the event stream reported a failure: \(detail)"
        }
    }

    var disconnectReason: DisconnectReason {
        switch self {
        case .descriptor(let error):
            switch error {
            case .notFound(let path): .runtimeNotRunning(path)
            case .missingToken: .unauthorized
            case .nonLoopbackHost, .insecurePermissions: .insecureDescriptor(error.description)
            case .malformed(let detail): .protocolBroken("bridge.json: \(detail)")
            default: .transport(error.description)
            }
        case .unauthorized: .unauthorized
        case .httpStatus(let status): .transport("HTTP \(status)")
        // 「读不懂对端的回答」自己是一类故障，不是泛泛的 transport：
        // 它意味着我们与 runtime 的版本/契约不一致，重启网络无济于事。
        case .malformedResponse(let detail): .protocolBroken(detail)
        case .nonForwardableMethod(let method): .transport("bad method \(method)")
        // 上游流报错：链路本身还在，但这条流不能再信 → 按传输故障重连。
        case .streamFaulted(let detail): .transport("stream/error: \(detail)")
        }
    }
}

/// 把一个非 `DSHClientError` 的传输层异常归类。
///
/// 存在的理由：旧实现把所有这些都糊成 `.transport(String(describing:))`，于是
/// 「surface 进程死了」（`cannotConnectToHost`）与「超时」（`timedOut`）在 UI 上
/// 完全一样，而这两者的下一步不同。
func classifyTransportFailure(_ error: any Error) -> DisconnectReason {
    guard let urlError = error as? URLError else {
        return .transport(String(describing: error))
    }
    switch urlError.code {
    case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
         .notConnectedToInternet, .dnsLookupFailed, .badServerResponse:
        // loopback 上「连不上」只有一个成因：那个端口上已经没有进程了。
        return .surfaceUnreachable(urlError.localizedDescription)
    case .timedOut:
        return .timedOut(urlError.localizedDescription)
    case .cannotParseResponse, .zeroByteResource:
        return .protocolBroken(urlError.localizedDescription)
    default:
        return .transport("URLError \(urlError.code.rawValue): \(urlError.localizedDescription)")
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

    public private(set) var link: RuntimeLinkState = .idle {
        didSet { noteAvailability() }
    }
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
    /// 「这一批帧之后必须重读一次列表」的原因（`nil` = 不必）。
    ///
    /// 增量能改的东西有限：会话是否 `blank`、以及会话属于哪个工作区，都只有
    /// `session.list` / `workspace.list` 知道（G-13）。所以列表相关的帧一律
    /// 只当作**失效信号**，真值仍然去问 runtime。
    public private(set) var pendingListRefresh: String?
    public private(set) var lastAgentError: String?

    // MARK: 链路可见性（本轮新增：失败不许被吞）

    /// 最近一次失败原因。**即使随后恢复也留痕** —— 「刚才为什么空了一下」
    /// 必须能从状态里回答，而不是只能从 os_log 里翻。
    public private(set) var lastFailure: DisconnectReason?
    /// 连续失败次数（一次「站稳」的连接把它归零）。退避就是按它算的。
    public private(set) var reconnectAttempt = 0
    /// 下一次自动重连要等多久（nil = 没有在等）。给 UI 说人话用。
    public private(set) var nextRetryDelay: TimeInterval?
    /// 用户手动点「重试」的次数（诊断：他点了几次都没成功）。
    public private(set) var manualRetryCount = 0

    /// 手上是否有过一份成功的全量快照。
    ///
    /// 「空」与「不知道」的分界线就是它：没有快照时说「暂无会话」是在替
    /// runtime 撒谎。
    public var hasSnapshot: Bool { snapshotLoadCount > 0 }

    // MARK: 依赖

    private let provider: any DSHConnectionProvider
    private let policy: ResumePolicy
    private let now: @Sendable () -> Date
    private let sleeper: SecondsSleepFunction

    @ObservationIgnored private var handle: DSHConnectionHandle?
    @ObservationIgnored private var disconnectedAt: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 本轮连接进入 `.live` 的时刻 —— 退避归零的判据（见 `ResumePolicy.stabilityWindow`）。
    @ObservationIgnored private var liveSince: Date?
    /// 上一轮连接是否「站稳」过。
    @ObservationIgnored private var lastRunWasStable = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.dsh.studio", category: "data-channel")

    public init(
        provider: any DSHConnectionProvider = LoopbackConnectionProvider(),
        policy: ResumePolicy = ResumePolicy(),
        now: (@Sendable () -> Date)? = nil,
        // 命名常量的默认值（DSHKit/InjectableClock.swift）：默认参数里的 async
        // 闭包字面量会在重连退避那一跳上让进程 abort。
        sleeper: SecondsSleepFunction? = nil
    ) {
        self.provider = provider
        self.policy = policy
        self.now = now ?? SystemClock.now
        self.sleeper = sleeper ?? SystemSleep.seconds
    }

    deinit {
        loop?.cancel()
    }

    // MARK: 生命周期

    /// 后台常驻：连接 → 消费事件流 → 断了退避重连。
    ///
    /// 退避计数只在一次连接**站稳**（`stabilityWindow`）之后归零。否则一个
    /// 「连上就断」的 runtime 会让我们以 `minimumBackoff` 的频率永久狂打它 ——
    /// 那种退避看得见、不生效。
    public func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let retry = await self.runOnce()
                guard retry, !Task.isCancelled else {
                    self.noteLoopStopped()
                    break
                }
                let attempt = self.advanceRetryCounter()
                let delay = self.policy.backoff(attempt: attempt)
                self.nextRetryDelay = delay
                try? await self.sleeper(delay)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        nextRetryDelay = nil
    }

    /// 用户点了「重试」。
    ///
    /// 三件事，缺一不可：退避计数归零（他等不了 10s）、丢掉旧 handle（token
    /// 可能已经换过一把）、把已经退出的循环重新拉起来 —— `unauthorized` 这类
    /// 不可重试的失败会让自动循环彻底停下，此时手动重试是**唯一**的复活路径。
    public func retryNow() {
        manualRetryCount += 1
        logger.notice("manual retry #\(self.manualRetryCount, privacy: .public) requested")
        loop?.cancel()
        loop = nil
        handle = nil
        reconnectAttempt = 0
        nextRetryDelay = nil
        link = .connecting
        start()
    }

    /// 退避计数推进一格；上一轮站稳过就先归零。
    private func advanceRetryCounter() -> Int {
        if lastRunWasStable { reconnectAttempt = 0 }
        reconnectAttempt += 1
        return reconnectAttempt
    }

    private func noteLoopStopped() {
        nextRetryDelay = nil
    }

    /// 一次「连接 + 消费到流结束」。返回值表示重试是否有意义。
    ///
    /// 单独暴露是为了让测试不必和后台循环赛跑。
    @discardableResult
    public func runOnce() async -> Bool {
        link = .connecting
        liveSince = nil
        lastRunWasStable = false
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
            // 连接被真实网络层拒绝/超时：分类而不是糊成一个字符串。
            markDisconnected(classifyTransportFailure(error))
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
        do {
            return try RPCReply.unwrap(value)
        } catch let envelope as RPCReply.EnvelopeError {
            // 「没读懂信封」是协议破坏，必须走失败态；不许退化成
            // 「上游说没有数据」（known-gaps G-11）。
            throw DSHClientError.malformedResponse("\(method): \(envelope.detail)")
        }
        // RPCFault（上游明确回了 ok:false）继续原样上抛：那是业务失败，
        // 不是链路失败，调用方各自处理。
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

    /// 手动拉一次全量快照。
    ///
    /// 失败也要**记在链路状态上**再抛：调用方（离屏渲染、诊断命令）可能只是
    /// `try?` 一下，而「快照没拉到」恰恰是 UI 必须知道的事。
    public func refreshSnapshot() async throws {
        do {
            try await refreshSnapshot(handle: try resolveHandle())
        } catch let error as DSHClientError {
            markDisconnected(error.disconnectReason)
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            markDisconnected(classifyTransportFailure(error))
            throw error
        }
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
        // ⚠️ 这两处解码曾经是 `try? … ?? 空表`。
        //
        // 那一行「保守兜底」正是本轮要修的 bug 的**源头**：上游把 `items` 改名、
        // 多一层包装、少一个必填字段 —— 任何一种漂移都会让这里静默产出一份
        // 「零个工作区、零个会话」的快照，`link` 却停在 `.live`。于是侧栏理直
        // 气壮地显示「暂无会话」，而真相是我们读不懂 runtime 的回答。
        //
        // 现在解不开就抛，归类为 `.protocolBroken`，UI 必须画成失败态。
        // 抛在赋值之前，所以上一份「已知良好」的投影不会被清空。
        let workspaceValue = try await rpcValue(.workspaceList, params: .object([:]), handle: handle)
        let workspaceList: WorkspaceListValue
        do {
            workspaceList = try workspaceValue.decoded(as: WorkspaceListValue.self)
        } catch {
            throw DSHClientError.malformedResponse("workspace.list: \(error)")
        }
        let sessionValue = try await rpcValue(.sessionList, params: .object([:]), handle: handle)
        let sessionList: SessionListValue
        do {
            sessionList = try sessionValue.decoded(as: SessionListValue.self)
        } catch {
            throw DSHClientError.malformedResponse("session.list: \(error)")
        }

        workspaces = workspaceList.items
        archivedSessionIDs = Set(workspaceList.archivedSessionIds)
        var table: [SessionID: SessionSummary] = [:]
        for row in sessionList.items {
            let merged = reconcile(row: row)
            table[row.sessionId] = merged
            if let asOf = merged.projections?.asOfSeq {
                lastSeqBySession[row.sessionId] = max(lastSeqBySession[row.sessionId] ?? -1, asOf)
            }
        }
        sessionsByID = table
        snapshotLoadCount += 1
        logger.notice("""
            snapshot #\(self.snapshotLoadCount, privacy: .public): \
            \(workspaceList.items.count, privacy: .public) workspace(s), \
            \(sessionList.items.count, privacy: .public) session(s), \
            \(self.visibleSessionCount, privacy: .public) displayable
            """)
        noteAvailability()
    }

    /// 把「界面这一刻画的是哪一态」写进日志，只在变化时写。
    ///
    /// 没有它，真机验证只能靠人对着屏幕转述；有了它，`empty → populated`
    /// 这条本轮 bug 的正解在日志里就是一行可检索的证据（G-13）。
    @ObservationIgnored private var lastLoggedAvailability: String?
    private func noteAvailability() {
        let label = dataAvailability.label
        let previous = lastLoggedAvailability
        guard label != previous else { return }
        lastLoggedAvailability = label
        logger.notice("""
            availability \(previous ?? "-", privacy: .public) → \
            \(label, privacy: .public) \
            (link=\(self.link.label, privacy: .public), \
            displayable=\(self.visibleSessionCount, privacy: .public), \
            snapshots=\(self.snapshotLoadCount, privacy: .public))
            """)
    }

    /// 把一行全量 `session.list` 和我们本地已应用的增量对齐。
    ///
    /// 分字段定权威，因为这几个字段的**来源根本不同**（上游 `api-proxy.ts`）：
    ///
    ///   * `running` ← `agent.status === 'running'`，是请求那一刻的活进程状态。
    ///     全量永远比任何早先的事件新 → **无条件听全量**。
    ///   * 成员关系（工作区归属 / 归档集合）← 只有全量有，增量里压根不广播 →
    ///     只认全量（G-13）。
    ///   * `blank` ← runtime 从会话事件日志折算。行里带 `projections.asOfSeq`，
    ///     那就是这一行消费到的事件序号（真机实测：空会话 `asOfSeq: 2`，发过一轮
    ///     的会话 `asOfSeq: 17`）；我们也知道自己应用到了第几号。若行落在我们
    ///     后面（读模型还没追上刚推来的 `turn/start`），就不许它把已经看见内容的
    ///     会话说回「空」—— 那是拿已知更旧的数据覆盖已知更新的数据，会让刚出现
    ///     的一行闪回「暂无会话」。`blank` 只单向变假。
    ///   * 投影（标题等）← 同样按 seq，高者胜。
    private func reconcile(row: SessionSummary) -> SessionSummary {
        guard let local = sessionsByID[row.sessionId] else { return row }
        let rowSeq = row.projections?.asOfSeq ?? -1
        var merged = row

        if let localProjections = local.projections, localProjections.asOfSeq > rowSeq {
            merged.projections = localProjections
            merged.updatedAt = max(row.updatedAt, local.updatedAt)
        }
        if (lastSeqBySession[row.sessionId] ?? -1) > rowSeq, !local.blank {
            merged.blank = false
            merged.updatedAt = max(row.updatedAt, local.updatedAt)
            logger.debug("""
                session.list row for \(row.sessionId.rawValue, privacy: .public) is behind our stream \
                (row seq \(rowSeq, privacy: .public)) → keeping blank=false
                """)
        }
        return merged
    }

    private func consumeEvents(handle: DSHConnectionHandle) async throws {
        var headers = handle.descriptor.authorizationHeaders
        headers["Accept"] = "text/event-stream"

        let gap = disconnectedAt.map { now().timeIntervalSince($0) } ?? .infinity
        switch policy.plan(lastEventID: lastEventID, disconnectedFor: gap) {
        case .resume(let identifier):
            // 断线续传：`Last-Event-ID` = seq（bridge-contract.md §2.3）。
            // 游标只决定「事件从哪接着听」，**不**决定「要不要重新对齐列表」。
            headers["Last-Event-ID"] = identifier
        case .fullResync:
            lastEventID = nil
        }

        // 每次（重）连都重新拉一次全量，续传也一样（known-gaps G-13）。
        //
        // 理由不是保守，而是增量**根本不足以**重建这份列表：
        //   1. 会话是否 `blank` 由上游从 session events 折出来（`turn/start`），
        //      host 流里**没有任何** frame 宣告 blank 翻转；
        //   2. 工作区与会话的归属（`WorkspaceView.sessionIds`）只在
        //      `workspace.list` 里，新建会话时上游**不发** `host/workspace-changed`
        //      （真机抓流确认：只有 `host/session-added`）。
        // 于是「只接着听增量」的必然结果就是：屏幕上是一份越来越旧的列表，
        // 而链路状态显示 `.live` —— 把故障伪装成现状，和把失败画成空态同罪。
        link = .resyncing
        try await refreshSnapshot(handle: handle)

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
        liveSince = now()
        disconnectedAt = nil
        logger.notice("data channel live (attempt \(self.reconnectAttempt, privacy: .public))")

        var parser = SSEParser()
        for try await chunk in chunks {
            for message in parser.consume(chunk) {
                if let identifier = message.id, !identifier.isEmpty {
                    lastEventID = identifier
                }
                guard let data = try? JSONValue.decode(json: message.data) else {
                    // 解析失败必须留痕：静默 continue 等于「事件丢了但没人知道」。
                    let name = message.event ?? "message"
                    unknownFrames.append("<malformed data for event `\(name)`>")
                    logger.error("""
                    dropped a frame we could not parse: event=\(name, privacy: .public) \
                    bytes=\(message.data.utf8.count, privacy: .public)
                    """)
                    // 丢了一帧就等于增量有洞 → 用全量兜回来，别带着窟窿继续 live。
                    pendingListRefresh = "unparsable `\(name)` frame"
                    continue
                }
                let frame = StreamFrame.decode(eventName: message.event, data: data)
                switch frame {
                case .replayGap(let requested, let oldest):
                    // bridge 说增量有洞（§2.3）。继续贴着旧数据装作 live 是最坏的
                    // 选择：屏幕上的东西已经不是真相了，而我们还在宣称一切正常。
                    // 丢掉游标、重新基线（G-12）。
                    logger.notice("""
                    replay gap: requested \(requested ?? -1, privacy: .public), \
                    oldest \(oldest ?? -1, privacy: .public) → re-baselining
                    """)
                    lastEventID = nil
                    pendingListRefresh = "replay gap"
                case .streamError(let fault):
                    // 上游明说这条流坏了 → 当成断连抛出去，交给退避重连，
                    // 而不是把它记进 unknownFrames 然后继续显示 live。
                    throw DSHClientError.streamFaulted(fault.description)
                default:
                    apply(frame)
                }
            }
            // 一个 chunk 里常常是一串帧（新建会话一次就来 5~6 帧）：合并成**一次**
            // 快照刷新，别对着 loopback 打 N 遍 RPC。
            if let reason = pendingListRefresh {
                pendingListRefresh = nil
                logger.notice("\(reason, privacy: .public) → re-reading the snapshot")
                link = .resyncing
                try await refreshSnapshot(handle: handle)
                link = .live(since: liveSince ?? now())
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
                // 会话刚从 blank 变成「有内容」：它大概还没进我们缓存里的
                // `workspace.sessionIds`（上游新建会话时不发 workspace-changed），
                // 所以归属关系必须重读，否则这一行永远出不来（G-13）。
                pendingListRefresh = "session left the blank state"
            case .turnEnd:
                summary.running = false
            case .userMessage:
                summary.blank = false
                pendingListRefresh = "session left the blank state"
            case .assistantMessage, .assistantChunk, .toolCall, .toolResult:
                summary.blank = false
            case .unknown(let value):
                // 上游加了新事件类型：不崩、不猜语义，只记账。
                unknownFrames.append(value["type"]?.stringValue ?? "session/?")
            }
            sessionsByID[identifier] = summary

        case .host(let hostFrame):
            // host/* 是列表的「有事发生」信号：具体新值去问 runtime（G-13）。
            pendingListRefresh = hostFrame.listInvalidationReason ?? pendingListRefresh
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

        // 这两种由 `consumeEvents` 直接处理（重新基线 / 抛断连），走到这里说明
        // 有人在测试里手动喂帧：记账即可，别假装应用成功了。
        case .replayGap, .streamError:
            unknownFrames.append("unhandled-out-of-band-frame")
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
    ///
    /// ⚠️ 这条过滤**不是** bug，别为了「让侧栏有东西」把它删掉：一个从没发生
    /// 过对话的 `blank` 会话在官方 UI 里同样不显示。本轮的 bug 在于过滤之后
    /// 得到的空列表与「连不上 runtime」画成了同一个样子，见 `dataAvailability`。
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

    /// 全部工作区 + 未分组里可显示的会话总数。
    public var visibleSessionCount: Int {
        workspaces.reduce(0) { $0 + visibleSessions(in: $1).count } + looseSessions().count
    }

    /// **三态判据（本轮的核心）** —— 视图只 `switch` 它，自己不推理。
    ///
    /// 顺序是有讲究的：
    ///
    /// 1. **有行就还画行**，哪怕此刻正在重连：已经看见过的会话是事实，清空列表
    ///    是另一种撒谎。但「还画行」不等于「一切正常」：链路不在 live 时给的是
    ///    `.stale`，界面必须同时说出「这些行可能已经不是现在的样子」。曾经这里
    ///    一律返回 `.populated`，于是 SSE 断掉之后侧栏能几个小时纹丝不动地
    ///    展示一份过期列表，看上去和正常运行毫无区别 —— 和「把失败画成空态」
    ///    是同一种病：拿一个我们无法保证的断言当结论（G-13）。
    /// 2. **失败优先于空。** 没有行、且链路是失败态 → `unavailable`。这是本轮
    ///    修的那个 bug：`disconnected` + 零行曾经被渲染成「暂无会话」，
    ///    也就是把一个**关于会话的断言**建立在一个**根本没拿到数据**的前提上。
    /// 3. **只有拿到过快照的 `.live`（或用户主动 stop）才敢说空。**
    ///    `hasSnapshot == false` 意味着我们对会话一无所知 → `pending`。
    public var dataAvailability: DataAvailability {
        let hasRows = visibleSessionCount > 0
        switch link {
        case .idle, .connecting, .resyncing:
            // 还在（重）连：有旧行就标成过期，没有就是 pending。
            return hasRows ? .stale(reason: nil, retryable: true) : .pending
        case .live:
            if hasRows { return .populated }
            return hasSnapshot ? .empty : .pending
        case .disconnected(let reason, _):
            // `.cancelled` 是我们自己停的（app 退出 / 手动 stop），不是故障：
            // 不该把一块告警画在正在关闭的界面上。
            if case .cancelled = reason {
                if hasRows { return .populated }
                return hasSnapshot ? .empty : .pending
            }
            if hasRows { return .stale(reason: reason, retryable: reason.isRetryable) }
            return .unavailable(reason: reason, retryable: reason.isRetryable)
        }
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
        // 这一轮活够久了吗 —— 退避归零的唯一判据。
        if let liveSince {
            lastRunWasStable = timestamp.timeIntervalSince(liveSince) >= policy.stabilityWindow
        }
        liveSince = nil
        disconnectedAt = timestamp
        link = .disconnected(reason: reason, since: timestamp)
        if case .cancelled = reason {
            // 我们自己停的，不留失败痕迹。
            return
        }
        lastFailure = reason
        // 失败必须能从日志回答，而不是只能从屏幕上猜（code 是稳定的机器可读键）。
        logger.error("""
            data channel down [\(reason.code, privacy: .public)] \(reason.description, privacy: .public) \
            — snapshot=\(self.hasSnapshot, privacy: .public) \
            displayable=\(self.visibleSessionCount, privacy: .public) \
            retryable=\(reason.isRetryable, privacy: .public)
            """)
    }
}
