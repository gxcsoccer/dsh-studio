import Testing
import Foundation
@testable import DSHKit
@testable import DSHClient

// MARK: - 测试替身

/// 可控时钟：断线续传窗口的判定完全靠它，测试不需要真的等两分钟。
///
/// `autoAdvancingBy` 让每次读钟自动前进 —— 用来表达「这一轮连接活了一会儿」
/// （退避归零的稳定窗口判据），而不必在后台循环里插手。
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private let step: TimeInterval

    init(_ value: Date = Date(timeIntervalSince1970: 1_700_000_000), autoAdvancingBy step: TimeInterval = 0) {
        self.value = value
        self.step = step
    }

    var current: Date {
        lock.lock(); defer { lock.unlock() }
        let snapshot = value
        value = value.addingTimeInterval(step)
        return snapshot
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

/// 无网络的数据通道传输替身：录请求、放脚本化的 SSE。
final class FakeTransport: DSHTransport, @unchecked Sendable {
    struct Recorded: Sendable {
        let path: String
        let headers: [String: String]
        let body: Data

        var method: String? {
            (try? JSONValue.decode(body))?["method"]?.stringValue
        }
    }

    private let lock = NSLock()
    private var _posts: [Recorded] = []
    private var _streams: [Recorded] = []
    private var _rpcValues: [String: JSONValue] = [:]
    /// 整包响应体覆盖（见 `setRawReplyBody`）：只给信封自身的用例。
    private var _rawBodies: [String: JSONValue] = [:]
    private var _postStatus = 200
    private var _streamStatus = 200
    private var _scripts: [String] = []
    /// 逐次消费的 `openStream` 状态码脚本（用完回落到 `streamStatus`）。
    private var _streamStatusScript: [Int] = []
    /// 注入的传输层异常（模拟 surface 进程死了 / 超时）。
    private var _postError: (any Error)?
    private var _streamError: (any Error)?
    /// 是否把流**挂住不结束** —— 这是唯一能让客户端停在 `.live` 的办法，
    /// 而 `.live` 恰恰是「敢说暂无会话」的前提，非测不可。
    private var _holdStream = false
    private var _held: [AsyncThrowingStream<Data, any Error>.Continuation] = []

    init(rpcValues: [String: JSONValue] = [:], scripts: [String] = []) {
        _rpcValues = rpcValues
        _scripts = scripts
    }

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var posts: [Recorded] { sync { _posts } }
    var streams: [Recorded] { sync { _streams } }

    var postStatus: Int {
        get { sync { _postStatus } }
        set { sync { _postStatus = newValue } }
    }

    var streamStatus: Int {
        get { sync { _streamStatus } }
        set { sync { _streamStatus = newValue } }
    }

    var postError: (any Error)? {
        get { sync { _postError } }
        set { sync { _postError = newValue } }
    }

    var streamError: (any Error)? {
        get { sync { _streamError } }
        set { sync { _streamError = newValue } }
    }

    var holdStreamOpen: Bool {
        get { sync { _holdStream } }
        set { sync { _holdStream = newValue } }
    }

    var heldStreamCount: Int { sync { _held.count } }

    /// 排一串 `openStream` 状态码：让「连 N 次都失败，第 N+1 次 401」这类
    /// 剧本可写，从而后台重连循环能**自然终止**（401 不可重试），测试不必和
    /// 一个永不停止的 loop 赛跑。
    func enqueueStreamStatuses(_ statuses: [Int]) {
        sync { _streamStatusScript.append(contentsOf: statuses) }
    }

    /// 结束被挂住的流（`error != nil` 时模拟传输中途炸掉）。
    func finishHeldStreams(throwing error: (any Error)? = nil) {
        let continuations = sync { () -> [AsyncThrowingStream<Data, any Error>.Continuation] in
            let held = _held
            _held = []
            return held
        }
        for continuation in continuations { continuation.finish(throwing: error) }
    }

    /// 往挂住的流里补一段 SSE 文本。
    func push(_ text: String) {
        let continuations = sync { _held }
        for continuation in continuations { continuation.yield(Data(text.utf8)) }
    }

    func setRPCValue(_ value: JSONValue, for method: RPCMethod) {
        sync { _rpcValues[method.rawValue] = value }
    }

    /// 让某个方法回一份**整个响应体**（绕过信封封装）。
    ///
    /// 只给「信封本身就是被测对象」的用例：真实 bridge 逐字转发上游
    /// `server-response`，所以默认路径必须走 `envelope(_:)`，不许各测试自己
    /// 编造包装——那正是 G-11 能藏进 200 个绿测试的原因。
    func setRawReplyBody(_ body: JSONValue, for method: RPCMethod) {
        sync { _rawBodies[method.rawValue] = body }
    }

    /// 生产线上真实的 `/rpc` 响应体（上游 `ServerResponse`，由 bridge 逐字转发）。
    static func envelope(_ value: JSONValue) -> JSONValue {
        .object([
            "type": .string("server-response"),
            "rpcId": .string(UUID().uuidString),
            "result": .object(["ok": .bool(true), "value": value]),
        ])
    }

    /// 排一段 SSE 文本；每次 `openStream` 消费一段，用完则立刻结束流。
    func enqueueScript(_ text: String) {
        sync { _scripts.append(text) }
    }

    func post(path: String, body: Data, headers: [String: String]) async throws -> HTTPReply {
        let record = Recorded(path: path, headers: headers, body: body)
        let (status, value, raw, error) = sync { () -> (Int, JSONValue, JSONValue?, (any Error)?) in
            _posts.append(record)
            let method = (try? JSONValue.decode(body))?["method"]?.stringValue ?? ""
            return (_postStatus, _rpcValues[method] ?? .object([:]), _rawBodies[method], _postError)
        }
        if let error { throw error }
        // ⚠️ 这里曾经回 `{ ok:true, value }` —— 一个真实 bridge **从不产生**的形状。
        // 于是 200 个测试全绿，而线上 `workspace.list` 永远解不开（G-11）。
        // 测试替身必须说线上那句话。
        let payload = raw ?? Self.envelope(value)
        return HTTPReply(status: status, body: try payload.encoded())
    }

    func openStream(
        path: String,
        headers: [String: String]
    ) async throws -> (status: Int, chunks: AsyncThrowingStream<Data, any Error>) {
        let record = Recorded(path: path, headers: headers, body: Data())
        let (status, script, error, hold) = sync { () -> (Int, String?, (any Error)?, Bool) in
            _streams.append(record)
            let status = _streamStatusScript.isEmpty ? _streamStatus : _streamStatusScript.removeFirst()
            return (status, _scripts.isEmpty ? nil : _scripts.removeFirst(), _streamError, _holdStream)
        }
        if let error { throw error }
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            if let script { continuation.yield(Data(script.utf8)) }
            if hold {
                sync { _held.append(continuation) }
            } else {
                continuation.finish()
            }
        }
        return (status, stream)
    }
}

struct FakeProvider: DSHConnectionProvider {
    let transport: FakeTransport
    var descriptor: BridgeDescriptor = BridgeDescriptor(token: "t0ken")
    var failure: BridgeDescriptorError?

    func connect() throws -> DSHConnectionHandle {
        if let failure { throw failure }
        return DSHConnectionHandle(descriptor: descriptor, transport: transport)
    }
}

private func sessionFrame(id: String, seq: Int, type: String, extra: [String: JSONValue] = [:]) -> String {
    let event = JSONValue.object([
        "type": .string(type),
        "seq": .number(Double(seq)),
        "time": .number(Double(1_700_000_000 + seq)),
        "data": .object(extra),
    ])
    let data = JSONValue.object(["sessionId": .string(id), "seq": .number(Double(seq)), "event": event])
    return "id: \(seq)\nevent: session\ndata: \((try? data.jsonText()) ?? "{}")\n\n"
}

private func hostFrame(_ fields: [String: JSONValue], seq: Int) -> String {
    "id: \(seq)\nevent: host\ndata: \((try? JSONValue.object(fields).jsonText()) ?? "{}")\n\n"
}

private func projectionFrame(id: String, key: String, value: JSONValue, seq: Int, eventID: Int) -> String {
    let data = JSONValue.object([
        "sessionId": .string(id),
        "key": .string(key),
        "value": value,
        "seq": .number(Double(seq)),
    ])
    return "id: \(eventID)\nevent: projection\ndata: \((try? data.jsonText()) ?? "{}")\n\n"
}

private func workspaceListValue(
    workspaceID: String = "w-1",
    sessions: [String] = ["s-1"]
) -> JSONValue {
    .object([
        "items": .array([.object([
            "workspaceId": .string(workspaceID),
            "path": .string("/tmp/demo"),
            "title": .string("demo"),
            "sessionIds": .array(sessions.map { .string($0) }),
            "createdAt": .string("2025-01-01"),
            "updatedAt": .string("2025-01-02"),
        ])]),
        "archivedSessionIds": .array([]),
    ])
}

/// 一份 `session.list` 全量。
///
/// `running` 必须由用例说清楚：上游这一列读的是 `agent.status`（请求那一刻的活
/// 进程状态，见 `api-proxy.ts` 的 `summarize`），所以全量刷新**理应**覆盖事件推断
/// 出来的 running。若某个用例先喂一帧 `running:true`、又让替身在随后的全量里回
/// `running:false`，那测的已经不是客户端，而是「替身在自我矛盾」——真 runtime
/// 永远不会这么答（G-11 的教训：替身说假话，测试就替 bug 背书）。
private func sessionListValue(
    _ ids: [String],
    blank: Bool = false,
    running: Bool = false
) -> JSONValue {
    .object(["items": .array(ids.map { id in
        .object([
            "sessionId": .string(id),
            "updatedAt": .number(1),
            "running": .bool(running),
            "blank": .bool(blank),
            "cwd": .string("/tmp/demo"),
        ])
    })])
}

// MARK: - 测试

@Suite("DSHClient：快照 + SSE 续传 + 失联")
@MainActor
struct DSHClientStreamTests {
    private func makeClient(
        transport: FakeTransport,
        clock: TestClock = TestClock(),
        failure: BridgeDescriptorError? = nil,
        policy: ResumePolicy = ResumePolicy()
    ) -> DSHClient {
        DSHClient(
            provider: FakeProvider(transport: transport, failure: failure),
            policy: policy,
            now: { clock.current },
            sleeper: { _ in }
        )
    }

    @Test("首次连接：先全量快照，再开流（不带 Last-Event-ID）")
    func firstRunTakesSnapshotThenStreams() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceListValue(),
            // 替身模拟「读模型还没追上」：行还写着 blank:true，且不带 asOfSeq。
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"], blank: true),
        ])
        transport.enqueueScript(sessionFrame(id: "s-1", seq: 5, type: "turn/start"))
        let client = makeClient(transport: transport)

        let retry = await client.runOnce()

        #expect(retry) // 流正常结束 → 重连有意义
        // 两次全量：连上先对齐一次，`turn/start` 让「谁该显示」失效后再对齐一次
        // （blank 与工作区归属都只有全量知道，G-13）。
        #expect(client.snapshotLoadCount == 2)
        #expect(transport.posts.map(\.method) == [
            "workspace.list", "session.list", // 连上先对齐
            "workspace.list", "session.list", // turn/start → 重读
        ])
        #expect(transport.posts.allSatisfy { $0.headers["Authorization"] == "Bearer t0ken" })
        #expect(transport.posts.allSatisfy { $0.path == "/rpc" })

        let stream = try #require(transport.streams.first)
        #expect(stream.path == "/events")
        #expect(stream.headers["Authorization"] == "Bearer t0ken")
        #expect(stream.headers["Accept"] == "text/event-stream")
        #expect(stream.headers["Last-Event-ID"] == nil)

        #expect(client.lastEventID == "5")
        #expect(client.workspaces.count == 1)
        // 全量那一行比我们的流旧，就不许它把已经发过话的会话说回「空」——
        // 否则刚出现的一行会闪回「暂无会话」。
        #expect(client.sessionsByID[SessionID("s-1")]?.blank == false)
        #expect(client.link == .disconnected(reason: .streamEnded, since: client.link.disconnectedSince ?? Date()))
    }

    /// 契约变更（G-13）：续传保留 `Last-Event-ID`（不丢事件），但**仍然**重拉
    /// 一次全量。原来「续传就不重拉」省下的那两个 loopback RPC，代价是列表可能
    /// 永久错误 —— `blank` 与工作区归属都不在增量里。
    @Test("断线续传：带 Last-Event-ID 接着听，同时重新对齐全量")
    func resumesWithLastEventID() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceListValue(),
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"]),
        ])
        transport.enqueueScript(sessionFrame(id: "s-1", seq: 5, type: "turn/start"))
        transport.enqueueScript(sessionFrame(id: "s-1", seq: 6, type: "turn/end"))
        let clock = TestClock()
        let client = makeClient(transport: transport, clock: clock)

        await client.runOnce()
        clock.advance(by: 3) // 断了 3s，远小于 120s 保留窗口
        await client.runOnce()

        // 1 连上对齐 + 2 `turn/start` 触发重读 + 3 重连再对齐。
        // （`turn/end` 只改 running，不影响成员，故不触发重读。）
        #expect(client.snapshotLoadCount == 3)
        #expect(transport.streams.count == 2)
        #expect(transport.streams[1].headers["Last-Event-ID"] == "5") // 游标没丢
        #expect(client.lastEventID == "6")
        #expect(client.sessionsByID[SessionID("s-1")]?.running == false)
    }

    @Test("断太久：放弃增量，重拉全量快照并清掉游标")
    func fullResyncAfterLongGap() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceListValue(),
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"]),
        ])
        transport.enqueueScript(sessionFrame(id: "s-1", seq: 5, type: "turn/start"))
        transport.enqueueScript(sessionFrame(id: "s-1", seq: 900, type: "turn/end"))
        let clock = TestClock()
        let client = makeClient(transport: transport, clock: clock, policy: ResumePolicy(retentionWindow: 120))

        await client.runOnce()
        clock.advance(by: 600) // 超出保留窗口
        await client.runOnce()

        #expect(client.snapshotLoadCount == 3) // 同上：对齐 + turn/start 重读 + 重连对齐
        #expect(transport.streams.count == 2)
        #expect(transport.streams[1].headers["Last-Event-ID"] == nil)
        #expect(client.lastEventID == "900")
    }

    @Test("token 被拒（401）→ 不再重试，状态可见")
    func unauthorizedIsTerminal() async throws {
        // 快照本身是好的（形状合法），被拒的是事件流 —— 否则先撞上的会是
        // 「读不懂 workspace.list」，测的就不是 401 了。
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceListValue(),
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"]),
        ])
        transport.streamStatus = 401
        let client = makeClient(transport: transport)
        let retry = await client.runOnce()
        #expect(retry == false)
        #expect(client.link.bannerText?.contains("token") == true)
        if case .disconnected(let reason, _) = client.link {
            #expect(reason == .unauthorized)
        } else {
            Issue.record("expected disconnected, got \(client.link)")
        }
    }

    @Test("bridge.json 不在 → runtime 未运行态，可重试")
    func missingDescriptorSurfacesAsRuntimeNotRunning() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, failure: .notFound(path: "/tmp/none/bridge.json"))
        let retry = await client.runOnce()
        #expect(retry)
        #expect(client.link == .disconnected(
            reason: .runtimeNotRunning("/tmp/none/bridge.json"),
            since: client.link.disconnectedSince ?? Date()
        ))
        #expect(client.link.bannerText?.contains("连不上 dsh runtime") == true)
        // 横幅必须把「下一步」也说出来（分类的价值全在这一栏）。
        #expect(client.link.bannerText?.contains("/tmp/none/bridge.json") == true)
        #expect(transport.streams.isEmpty)
    }

    @Test("descriptor 里没 token → 按未授权处理，不做匿名请求")
    func missingTokenIsUnauthorized() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, failure: .missingToken(path: "/tmp/bridge.json"))
        let retry = await client.runOnce()
        #expect(retry == false)
        #expect(transport.posts.isEmpty)
    }

    @Test("descriptor 不安全（非 loopback / 权限太松）→ 拒绝且不重试")
    func insecureDescriptorIsTerminal() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, failure: .nonLoopbackHost("0.0.0.0"))
        #expect(await client.runOnce() == false)
        #expect(client.link.bannerText?.contains("拒绝连接") == true)
    }

    @Test("快照 HTTP 5xx → 可重试的传输失败")
    func snapshotServerErrorIsRetryable() async throws {
        let transport = FakeTransport()
        transport.postStatus = 503
        let client = makeClient(transport: transport)
        #expect(await client.runOnce())
        #expect(client.link.bannerText?.contains("HTTP 503") == true)
    }

    @Test("坏掉的 SSE data 不中断流，只记账，并用全量兜回丢掉的那一帧")
    func malformedFrameIsRecorded() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceListValue(),
            // 真 runtime 在 turn/start 之后就是这么答的：跑着、且不再是空会话。
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"], running: true),
        ])
        transport.enqueueScript("id: 1\nevent: session\ndata: not json\n\n" + sessionFrame(id: "s-1", seq: 2, type: "turn/start"))
        let client = makeClient(transport: transport)
        await client.runOnce()
        #expect(client.unknownFrames.count == 1)
        // 解不开一帧 = 增量有洞。记账之外还必须重读全量，否则我们会带着窟窿
        // 继续宣称 live（G-13）。
        #expect(client.snapshotLoadCount == 2)
        #expect(client.sessionsByID[SessionID("s-1")]?.running == true)
        #expect(client.sessionsByID[SessionID("s-1")]?.blank == false)
    }

    /// 两件事一起钉：`event: host` / mux 投影帧确实被解码进状态机；随后的全量
    /// 刷新**不会**把比它更新的投影擦掉（否则表现为「标题闪一下就没了」）。
    @Test("host / projection 帧驱动侧栏，且不被随后的全量刷新擦掉")
    func consumesHostAndProjectionFrames() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceListValue(sessions: ["s-1"]),
            // 全量里这一行还没带上标题（投影走增量先到）——正是会擦掉标题的时序。
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"], running: true),
        ])
        transport.enqueueScript(
            hostFrame(["type": .string("host/session-status"), "sessionId": .string("s-1"), "running": .bool(true)], seq: 1)
            + projectionFrame(id: "s-1", key: "title", value: .string("重构侧栏"), seq: 4, eventID: 2)
            + hostFrame(["type": .string("host/telepathy")], seq: 3)
        )
        let client = makeClient(transport: transport)
        await client.runOnce()

        #expect(client.sessionsByID[SessionID("s-1")]?.running == true)
        #expect(client.sessionsByID[SessionID("s-1")]?.projections?.title == "重构侧栏")
        #expect(client.unknownFrames == ["host/telepathy"])
        #expect(client.lastEventID == "3")
        // host/* 是列表失效信号（连没建模的 host/telepathy 也算）→ 重读一次。
        #expect(client.snapshotLoadCount == 2)
    }

    @Test("studio.* 不许走官方 /rpc 转发面")
    func refusesNonForwardableMethod() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        await #expect(throws: DSHClientError.nonForwardableMethod("studio.openSettings")) {
            _ = try await client.rpcValue(RPCMethod(rawValue: "studio.openSettings"))
        }
        #expect(transport.posts.isEmpty)
    }

    @Test("领域动作走数据通道：session.create / workspace.archiveSession")
    func domainActionsUseDataChannel() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.sessionCreate.rawValue: .object(["sessionId": .string("s-new")]),
            RPCMethod.workspaceArchiveSession.rawValue: .object(["archivedSessionIds": .array([.string("s-1")])]),
        ])
        let client = makeClient(transport: transport)

        let created = try await client.createSession(in: WorkspaceID("w-1"))
        #expect(created == SessionID("s-new"))
        let body = try #require(transport.posts.first.map { try? JSONValue.decode($0.body) } ?? nil)
        #expect(body["method"]?.stringValue == "session.create")
        #expect(body["params"]?["workspaceId"]?.stringValue == "w-1")

        try await client.archiveSession(SessionID("s-1"))
        #expect(client.archivedSessionIDs == [SessionID("s-1")])
    }
}

@Suite("DSHClient：投影缓存的合并规则")
@MainActor
struct DSHClientProjectionTests
{
    private func makeClient() -> DSHClient {
        DSHClient(provider: FakeProvider(transport: FakeTransport()), now: { Date(timeIntervalSince1970: 1) }, sleeper: { _ in })
    }

    private func frame(_ id: String, seq: Int, type: String) -> StreamFrame {
        .session(SessionFrame(
            sessionId: SessionID(id),
            seq: seq,
            event: SessionEventRecord(type: type, seq: seq, time: Double(1_700_000_000 + seq))
        ))
    }

    @Test("以 seq 为序：重放的老事件不许覆盖新状态")
    func oldEventsDoNotOverwrite() {
        let client = makeClient()
        client.apply(frame("s-1", seq: 10, type: "turn/start"))
        #expect(client.sessionsByID[SessionID("s-1")]?.running == true)

        // 重连后重放了一条更老的 turn/end：必须被忽略。
        client.apply(frame("s-1", seq: 4, type: "turn/end"))
        #expect(client.sessionsByID[SessionID("s-1")]?.running == true)
        #expect(client.lastSeqBySession[SessionID("s-1")] == 10)

        client.apply(frame("s-1", seq: 11, type: "turn/end"))
        #expect(client.sessionsByID[SessionID("s-1")]?.running == false)
    }

    @Test("投影 higher-seq-wins")
    func projectionsUseWatermark() {
        let client = makeClient()
        client.apply(.projection(ProjectionFrame(sessionId: SessionID("s-1"), key: "title", value: .string("新标题"), seq: 9)))
        client.apply(.projection(ProjectionFrame(sessionId: SessionID("s-1"), key: "title", value: .string("旧标题"), seq: 3)))
        #expect(client.sessionsByID[SessionID("s-1")]?.projections?.title == "新标题")
        #expect(client.projectionSeq[SessionID("s-1")]?["title"] == 9)
    }

    @Test("未知事件类型只记账，不猜语义")
    func unknownEventsAreAccounted() {
        let client = makeClient()
        client.apply(.session(SessionFrame(
            sessionId: SessionID("s-1"),
            seq: 1,
            event: SessionEventRecord(type: "assistant/hologram", seq: 1, time: 0)
        )))
        #expect(client.unknownFrames == ["assistant/hologram"])
        #expect(client.sessionsByID[SessionID("s-1")] != nil) // 会话仍然存在，只是状态不变
    }

    @Test("host/session-removed 清掉所有相关缓存")
    func removalClearsCaches() {
        let client = makeClient()
        client.apply(frame("s-1", seq: 3, type: "turn/start"))
        client.apply(.projection(ProjectionFrame(sessionId: SessionID("s-1"), key: "title", value: .string("t"), seq: 3)))
        client.apply(.host(.sessionRemoved(SessionID("s-1"))))
        #expect(client.sessionsByID.isEmpty)
        #expect(client.lastSeqBySession.isEmpty)
        #expect(client.projectionSeq.isEmpty)
    }

    @Test("工作区顺序变更按给定顺序重排")
    func reordersWorkspaces() {
        let client = makeClient()
        client.apply(.host(.workspaceChanged(WorkspaceView(workspaceId: WorkspaceID("w-1"), path: "/a", title: "A", sessionIds: []))))
        client.apply(.host(.workspaceChanged(WorkspaceView(workspaceId: WorkspaceID("w-2"), path: "/b", title: "B", sessionIds: []))))
        client.apply(.host(.workspaceOrderChanged([WorkspaceID("w-2"), WorkspaceID("w-1")])))
        #expect(client.workspaces.map(\.workspaceId) == [WorkspaceID("w-2"), WorkspaceID("w-1")])
    }

    @Test("侧栏读模型：按工作区顺序，隐去归档与空会话")
    func sidebarReadModel() {
        let client = makeClient()
        let workspace = WorkspaceView(
            workspaceId: WorkspaceID("w-1"),
            path: "/a",
            title: "A",
            sessionIds: [SessionID("s-3"), SessionID("s-1"), SessionID("s-blank"), SessionID("s-archived")]
        )
        client.apply(.host(.workspaceChanged(workspace)))
        for id in ["s-1", "s-3", "s-archived"] {
            client.apply(.host(.sessionAdded(SessionSummary(sessionId: SessionID(id), updatedAt: 1, running: false, blank: false))))
        }
        client.apply(.host(.sessionAdded(SessionSummary(sessionId: SessionID("s-blank"), updatedAt: 1, running: false, blank: true))))
        client.apply(.host(.archivedSessionsChanged([SessionID("s-archived")])))

        #expect(client.visibleSessions(in: workspace).map(\.sessionId) == [SessionID("s-3"), SessionID("s-1")])
        #expect(client.looseSessions().isEmpty)
        #expect(client.runningSessionCount == 0)

        client.apply(.host(.sessionStatus(SessionID("s-1"), running: true)))
        #expect(client.runningSessionCount == 1)
    }

    @Test("不属于任何工作区的会话按更新时间倒序")
    func looseSessionsSorted() {
        let client = makeClient()
        client.apply(.host(.sessionAdded(SessionSummary(sessionId: SessionID("s-old"), updatedAt: 10, running: false, blank: false))))
        client.apply(.host(.sessionAdded(SessionSummary(sessionId: SessionID("s-new"), updatedAt: 99, running: false, blank: false))))
        #expect(client.looseSessions().map(\.sessionId) == [SessionID("s-new"), SessionID("s-old")])
    }

    @Test("host/session-added 不覆盖已知的 running 与投影")
    func sessionAddedKeepsLocalState() {
        let client = makeClient()
        client.apply(frame("s-1", seq: 2, type: "turn/start"))
        client.apply(.projection(ProjectionFrame(sessionId: SessionID("s-1"), key: "title", value: .string("t"), seq: 2)))
        client.apply(.host(.sessionAdded(SessionSummary(sessionId: SessionID("s-1"), updatedAt: 5, running: false, blank: true))))
        #expect(client.sessionsByID[SessionID("s-1")]?.running == true)
        #expect(client.sessionsByID[SessionID("s-1")]?.projections?.title == "t")
    }
}

extension RuntimeLinkState {
    /// 测试便利：断连时间戳（断言里不必猜时钟）。
    var disconnectedSince: Date? {
        guard case .disconnected(_, let since) = self else { return nil }
        return since
    }
}
