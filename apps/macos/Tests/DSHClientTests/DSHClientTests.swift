import Testing
import Foundation
@testable import DSHKit
@testable import DSHClient

// MARK: - 测试替身

/// 可控时钟：断线续传窗口的判定完全靠它，测试不需要真的等两分钟。
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.value = value
    }

    var current: Date {
        lock.lock(); defer { lock.unlock() }
        return value
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
    private var _postStatus = 200
    private var _streamStatus = 200
    private var _scripts: [String] = []

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

    func setRPCValue(_ value: JSONValue, for method: RPCMethod) {
        sync { _rpcValues[method.rawValue] = value }
    }

    /// 排一段 SSE 文本；每次 `openStream` 消费一段，用完则立刻结束流。
    func enqueueScript(_ text: String) {
        sync { _scripts.append(text) }
    }

    func post(path: String, body: Data, headers: [String: String]) async throws -> HTTPReply {
        let record = Recorded(path: path, headers: headers, body: body)
        let (status, value) = sync { () -> (Int, JSONValue) in
            _posts.append(record)
            let method = (try? JSONValue.decode(body))?["method"]?.stringValue ?? ""
            return (_postStatus, _rpcValues[method] ?? .object([:]))
        }
        let payload = JSONValue.object(["ok": .bool(true), "value": value])
        return HTTPReply(status: status, body: try payload.encoded())
    }

    func openStream(
        path: String,
        headers: [String: String]
    ) async throws -> (status: Int, chunks: AsyncThrowingStream<Data, any Error>) {
        let record = Recorded(path: path, headers: headers, body: Data())
        let (status, script) = sync { () -> (Int, String?) in
            _streams.append(record)
            return (_streamStatus, _scripts.isEmpty ? nil : _scripts.removeFirst())
        }
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            if let script { continuation.yield(Data(script.utf8)) }
            continuation.finish()
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

private func sessionListValue(_ ids: [String], blank: Bool = false) -> JSONValue {
    .object(["items": .array(ids.map { id in
        .object([
            "sessionId": .string(id),
            "updatedAt": .number(1),
            "running": .bool(false),
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
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"]),
        ])
        transport.enqueueScript(sessionFrame(id: "s-1", seq: 5, type: "turn/start"))
        let client = makeClient(transport: transport)

        let retry = await client.runOnce()

        #expect(retry) // 流正常结束 → 重连有意义
        #expect(client.snapshotLoadCount == 1)
        #expect(transport.posts.map(\.method) == ["workspace.list", "session.list"])
        #expect(transport.posts.allSatisfy { $0.headers["Authorization"] == "Bearer t0ken" })
        #expect(transport.posts.allSatisfy { $0.path == "/rpc" })

        let stream = try #require(transport.streams.first)
        #expect(stream.path == "/events")
        #expect(stream.headers["Authorization"] == "Bearer t0ken")
        #expect(stream.headers["Accept"] == "text/event-stream")
        #expect(stream.headers["Last-Event-ID"] == nil)

        #expect(client.lastEventID == "5")
        #expect(client.workspaces.count == 1)
        #expect(client.sessionsByID[SessionID("s-1")]?.running == true)
        #expect(client.link == .disconnected(reason: .streamEnded, since: client.link.disconnectedSince ?? Date()))
    }

    @Test("断线续传：第二次连接带 Last-Event-ID，且不重拉快照")
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

        #expect(client.snapshotLoadCount == 1) // 没有第二次全量
        #expect(transport.streams.count == 2)
        #expect(transport.streams[1].headers["Last-Event-ID"] == "5")
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

        #expect(client.snapshotLoadCount == 2)
        #expect(transport.streams.count == 2)
        #expect(transport.streams[1].headers["Last-Event-ID"] == nil)
        #expect(client.lastEventID == "900")
    }

    @Test("token 被拒（401）→ 不再重试，状态可见")
    func unauthorizedIsTerminal() async throws {
        let transport = FakeTransport()
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
        #expect(client.link.bannerText == "与 dsh runtime 失联：runtime 未运行")
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

    @Test("坏掉的 SSE data 不中断流，只记账")
    func malformedFrameIsRecorded() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceListValue(),
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"]),
        ])
        transport.enqueueScript("id: 1\nevent: session\ndata: not json\n\n" + sessionFrame(id: "s-1", seq: 2, type: "turn/start"))
        let client = makeClient(transport: transport)
        await client.runOnce()
        #expect(client.unknownFrames.count == 1)
        #expect(client.sessionsByID[SessionID("s-1")]?.running == true)
    }

    @Test("host / projection 帧驱动侧栏（契约缺口：文档只写了 event: session）")
    func consumesHostAndProjectionFrames() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceListValue(sessions: ["s-1"]),
            RPCMethod.sessionList.rawValue: sessionListValue(["s-1"]),
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
