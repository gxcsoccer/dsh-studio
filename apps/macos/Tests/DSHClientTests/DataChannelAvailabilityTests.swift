import Testing
import Foundation
@testable import DSHKit
@testable import DSHClient

// MARK: - 这个文件钉的是什么

/// **「数据通道失败绝不渲染成空态」的回归网。**
///
/// 被修的 bug：原生侧栏只区分「没有会话」与「搜索无匹配」，于是 runtime 没起、
/// token 失效、surface 进程死掉、上游把 `items` 改了名 —— 全部被渲染成一句
/// 温和的「暂无会话」。那是一句**关于用户数据的断言**，建立在一个**根本没拿到
/// 数据的前提**上；用户会以为自己的会话不见了，而真相是我们连不上。
///
/// 所以这里的每个用例都在回答同一个问题：**此刻我们凭什么敢说「空」？**
/// 答案只有一个 —— 拿到过一份能读懂的快照，且链路是活的。其余一切情况都必须
/// 是 `pending` 或 `unavailable`，且带上可诊断的原因与下一步。

// MARK: - 测试辅助

/// 记录退避时长的假睡眠。退避是「多久打一次」的策略，测试要断言的是**节律**，
/// 不是真的等 10 秒。
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []

    var delays: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _delays
    }

    /// 同步方法：`NSLock.lock()` 在 async 上下文里不可用（会阻塞协作线程池），
    /// 所以加锁必须发生在一个普通的同步函数里，async 闭包只负责调用它。
    private func record(_ delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _delays.append(delay)
    }

    /// 注意：这里必须是**命名属性**返回的闭包，不能写成 `DSHClient` 默认参数里的
    /// 闭包字面量（DSHKit/InjectableClock.swift 记的那个 SIGABRT 坑）。
    var sleeper: SecondsSleepFunction {
        { [self] delay in record(delay) }
    }
}

extension DataAvailability {
    /// 失败原因的机器可读 code（非失败态为 nil）。断言用它，不 grep 中文文案。
    var failureCode: String? {
        guard case .unavailable(let reason, _) = self else { return nil }
        return reason.code
    }

    var isRetryableFailure: Bool? {
        guard case .unavailable(_, let retryable) = self else { return nil }
        return retryable
    }
}

/// 有界轮询：等后台循环/并发的 `runOnce` 推进到某个状态。
///
/// 有界是刻意的 —— 一个永远等不到的条件应该是**失败的测试**，不是挂住的 CI。
@MainActor
private func waitUntil(
    _ label: String,
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<20_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("等待超时：\(label)", sourceLocation: sourceLocation)
}

private func workspaces(_ sessionIDs: [String], id: String = "w-1") -> JSONValue {
    .object([
        "items": .array([.object([
            "workspaceId": .string(id),
            "path": .string("/tmp/demo"),
            "title": .string("demo"),
            "sessionIds": .array(sessionIDs.map { .string($0) }),
            "createdAt": .string("2025-01-01"),
            "updatedAt": .string("2025-01-02"),
        ])]),
        "archivedSessionIds": .array([]),
    ])
}

private func sessions(_ items: [(id: String, blank: Bool)]) -> JSONValue {
    .object(["items": .array(items.map { item in
        .object([
            "sessionId": .string(item.id),
            "updatedAt": .number(1),
            "running": .bool(false),
            "blank": .bool(item.blank),
            "cwd": .string("/tmp/demo"),
        ])
    })])
}

/// 用户此刻真实的处境：一个工作区、唯一的会话是 `blank`（从没对话过）。
/// 官方 UI 也不显示它 —— 所以「零行」本身是对的，错的是**把失败画成零行**。
private func blankOnlyTransport() -> FakeTransport {
    FakeTransport(rpcValues: [
        RPCMethod.workspaceList.rawValue: workspaces(["s-blank"]),
        RPCMethod.sessionList.rawValue: sessions([(id: "s-blank", blank: true)]),
    ])
}

private func populatedTransport() -> FakeTransport {
    FakeTransport(rpcValues: [
        RPCMethod.workspaceList.rawValue: workspaces(["s-1"]),
        RPCMethod.sessionList.rawValue: sessions([(id: "s-1", blank: false)]),
    ])
}

// MARK: - 三态判据

@Suite("数据通道：失败绝不渲染成空态")
@MainActor
struct DataChannelAvailabilityTests {
    private func makeClient(
        transport: FakeTransport,
        clock: TestClock = TestClock(),
        failure: BridgeDescriptorError? = nil,
        policy: ResumePolicy = ResumePolicy(),
        sleeper: SecondsSleepFunction? = nil
    ) -> DSHClient {
        DSHClient(
            provider: FakeProvider(transport: transport, failure: failure),
            policy: policy,
            now: { clock.current },
            sleeper: sleeper ?? { _ in }
        )
    }

    /// 让客户端停在 `.live`（流挂住不结束），返回那个还在跑的 `runOnce`。
    private func goLive(_ client: DSHClient, _ transport: FakeTransport) async -> Task<Bool, Never> {
        transport.holdStreamOpen = true
        let run = Task { await client.runOnce() }
        await waitUntil("链路进入 live") { client.link.isLive }
        return run
    }

    // MARK: 线上真实响应形状（G-11）

    /// 这条用例是本轮 bug 的**真正**回归测试。
    ///
    /// 它不用 `FakeTransport` 的便利封装，而是把真机抓下来的整包响应体原样喂进去：
    /// `{type:"server-response",rpcId,result:{ok:true,value:{items:[…]}}}`。
    /// 修复前，这份**完全健康**的回答会被解成「零个工作区」→ 侧栏「暂无会话」。
    @Test("真机 server-response 信封 → populated（不是空态、也不是失败）")
    func liveEnvelopeYieldsPopulated() async throws {
        let transport = FakeTransport()
        transport.setRawReplyBody(
            try JSONValue.decode(Data("""
            {"type":"server-response","rpcId":"84ebdbd1","result":{"ok":true,"value":{
              "items":[{"workspaceId":"f42ee878","path":"/Users/bytedance/Workspace","title":"Workspace",
                        "sessionIds":["session-d7beff90"],
                        "createdAt":"2026-08-17T14:17:46.369Z","updatedAt":"2026-08-17T14:17:46.429Z"}],
              "archivedSessionIds":[]}}}
            """.utf8)),
            for: .workspaceList
        )
        transport.setRawReplyBody(
            try JSONValue.decode(Data("""
            {"type":"server-response","rpcId":"c0ffee","result":{"ok":true,"value":{
              "items":[{"sessionId":"session-d7beff90","updatedAt":1,"running":false,"blank":false,
                        "cwd":"/Users/bytedance/Workspace"}]}}}
            """.utf8)),
            for: .sessionList
        )
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)

        #expect(client.dataAvailability == .populated)
        #expect(client.lastFailure == nil)
        #expect(client.workspaces.first?.path == "/Users/bytedance/Workspace")
        #expect(client.visibleSessionCount == 1)
        run.cancel()
        _ = await run.value
    }

    /// 反向钉子：信封换了形状（上游改包装 / 我们读错层）**必须**是失败态。
    /// 修复前这里会安静地变成「零个工作区」。
    @Test("信封不是我们认识的形状 → protocol-broken 失败态，绝不是空态（G-11）")
    func unknownEnvelopeIsFailureNotEmpty() async throws {
        let transport = FakeTransport()
        // 少了一层 result：正是「我们读错层」的样子。
        transport.setRawReplyBody(
            try JSONValue.decode(Data(#"{"type":"server-response","rpcId":"x","value":{"items":[]}}"#.utf8)),
            for: .workspaceList
        )
        let client = makeClient(transport: transport)
        let run = Task { await client.runOnce() }
        await waitUntil("链路报失败") { client.lastFailure != nil }

        #expect(client.dataAvailability.isUnavailable)
        #expect(client.dataAvailability != .empty)
        #expect(client.lastFailure?.code == "protocol-broken")
        #expect(client.hasSnapshot == false)
        run.cancel()
        _ = await run.value
    }

    @Test("上游回 ok:false 业务错误 → 也不是空态")
    func businessErrorIsNotEmpty() async throws {
        let transport = FakeTransport()
        transport.setRawReplyBody(
            try JSONValue.decode(Data("""
            {"type":"server-response","rpcId":"x","result":{"ok":false,
             "error":{"code":"internal","message":"boom","details":{}}}}
            """.utf8)),
            for: .workspaceList
        )
        let client = makeClient(transport: transport)
        let run = Task { await client.runOnce() }
        await waitUntil("链路报失败") { client.lastFailure != nil }

        #expect(client.dataAvailability.isUnavailable)
        #expect(client.dataAvailability != .empty)
        run.cancel()
        _ = await run.value
    }

    // MARK: 快照必须跟着事件走（G-13：静止的旧列表也是在说谎）

    /// 用户报的第二个 bug：app 启动时只有 blank 会话 →「暂无会话」（当时正确）；
    /// 之后聊出了会话「123」，原生栏**一直没变**。
    ///
    /// 真机抓流确认：新建会话只来 `host/session-added`，工作区归属不广播，
    /// `blank` 翻转更是完全没有 frame。所以「收到事件就地合并」不可能对，
    /// 必须把事件当失效信号、回头重读全量。
    @Test("会话变更事件到达 → 重新拉快照，新会话真的出现在侧栏")
    func sessionEventTriggersSnapshotRefresh() async throws {
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaces([]),
            RPCMethod.sessionList.rawValue: sessions([]),
        ])
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)
        #expect(client.dataAvailability == .empty) // 起点：真的没有可显示会话
        #expect(client.snapshotLoadCount == 1)

        // runtime 侧真的多了一个非空会话，并且进了工作区的 sessionIds。
        transport.setRPCValue(workspaces(["s-new"]), for: .workspaceList)
        transport.setRPCValue(sessions([(id: "s-new", blank: false)]), for: .sessionList)
        // host 只告诉我们「加了个会话」（而且宣称 blank=true —— 片段就是这么片面）。
        transport.push("""
        id: 7
        event: host
        data: {"type":"host/session-added","sessionId":"s-new","blank":true,"cwd":"/tmp/demo"}


        """)

        await waitUntil("快照被事件驱动刷新") { client.snapshotLoadCount == 2 }
        #expect(client.dataAvailability == .populated)
        #expect(client.visibleSessionCount == 1)
        #expect(client.link.isLive)
        run.cancel()
        _ = await run.value
    }

    @Test("一个 chunk 里一串帧 → 只重读一次快照（不打 N 遍 RPC）")
    func burstOfFramesCoalescesIntoOneRefresh() async throws {
        let transport = populatedTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)
        #expect(client.snapshotLoadCount == 1)

        transport.push("""
        id: 10
        event: host
        data: {"type":"host/session-added","sessionId":"s-a","blank":true}

        id: 11
        event: host
        data: {"type":"host/session-status","sessionId":"s-a","running":true}

        id: 12
        event: host
        data: {"type":"host/workspace-order-changed","workspaceIds":["w-1"]}


        """)
        await waitUntil("刷新一次") { client.snapshotLoadCount == 2 }
        // 再等一拍，确认没有第三、第四次。
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(client.snapshotLoadCount == 2)
        run.cancel()
        _ = await run.value
    }

    @Test("解析不了的帧：留痕 + 兜一次全量，绝不静默丢弃")
    func unparsableFrameIsDiagnosedAndRecovered() async throws {
        let transport = populatedTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)

        transport.push("id: 13\nevent: host\ndata: {this is not json\n\n")
        await waitUntil("丢帧被兜回来") { client.snapshotLoadCount == 2 }
        #expect(client.unknownFrames.contains { $0.contains("malformed data") })
        run.cancel()
        _ = await run.value
    }

    /// 上游加了一种我们没建模的 host frame：不许「记账后继续显示旧列表」。
    @Test("不认识的 host frame 也算列表失效 → 去重读，而不是假装无事")
    func unmodelledHostFrameStillRefreshes() async throws {
        let transport = populatedTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)

        transport.push("""
        id: 14
        event: host
        data: {"type":"host/session-pinned","sessionId":"s-1"}


        """)
        await waitUntil("未知 host frame 触发重读") { client.snapshotLoadCount == 2 }
        run.cancel()
        _ = await run.value
    }

    @Test("流断了 → 旧列表标成过期，绝不继续当现状（G-13）")
    func brokenStreamIsFailureNotStaleData() async throws {
        let transport = populatedTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)
        #expect(client.dataAvailability == .populated)

        transport.finishHeldStreams(throwing: URLError(.networkConnectionLost))
        await waitUntil("链路报失败") { client.lastFailure != nil }

        // 旧数据还在（清屏是另一种撒谎），但它**不再是现状**：
        // `.stale` 让界面必须说出「以上可能已过期」，而 `.populated` 会让一份
        // 冻住的列表和正常运行长得一模一样。
        #expect(client.dataAvailability.isCurrent == false)
        #expect(client.dataAvailability.hasRows) // 行没被清空
        if case .stale(let reason, let retryable) = client.dataAvailability {
            #expect(reason?.code == "stream-broken" || reason?.isRetryable == true)
            #expect(retryable)
        } else {
            Issue.record("expected .stale, got \(client.dataAvailability)")
        }
        #expect(client.hasSnapshot)
        #expect(client.link.isLive == false)
        run.cancel()
        _ = await run.value
    }

    /// 用户给的真实数据做 fixture：15 个 sessionIds 里 14 个 blank + 1 个非空
    /// （title="123"）→ 侧栏应当**恰好**一行。
    @Test("真实数据 fixture：15 个 sessionIds 里只有「123」该显示")
    func realWorldFixtureYieldsExactlyOneRow() async throws {
        var sessionIDs = (0..<14).map { "session-blank-\($0)" }
        sessionIDs.append("session-51c33595")
        let workspaceValue = JSONValue.object([
            "items": .array([.object([
                "workspaceId": .string("w-real"),
                "path": .string("/Users/bytedance/Workspace"),
                "title": .string("Workspace"),
                "sessionIds": .array(sessionIDs.map { .string($0) }),
                "createdAt": .string("2026-08-17T14:17:46.369Z"),
                "updatedAt": .string("2026-08-17T14:17:46.429Z"),
            ])]),
            "archivedSessionIds": .array([]),
        ])
        var rows: [JSONValue] = sessionIDs.dropLast().map { id in
            .object([
                "sessionId": .string(id),
                "updatedAt": .number(1),
                "running": .bool(false),
                "blank": .bool(true),
                "cwd": .string("/Users/bytedance/Workspace"),
            ])
        }
        rows.append(.object([
            "sessionId": .string("session-51c33595"),
            "updatedAt": .number(2),
            "running": .bool(false),
            "blank": .bool(false),
            "cwd": .string("/Users/bytedance/Workspace"),
            "projections": .object([
                "asOfSeq": .number(3),
                "values": .object(["title": .string("123")]),
            ]),
        ]))
        let transport = FakeTransport(rpcValues: [
            RPCMethod.workspaceList.rawValue: workspaceValue,
            RPCMethod.sessionList.rawValue: .object(["items": .array(rows)]),
        ])
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)

        let workspace = try #require(client.workspaces.first)
        let visible = client.visibleSessions(in: workspace)
        #expect(visible.count == 1)
        #expect(visible.first?.projections?.title == "123")
        #expect(client.dataAvailability == .populated)
        run.cancel()
        _ = await run.value
    }

    // MARK: bridge 主动说话时必须听（G-12）

    /// 真机复现过的场景：runtime 重启后 ring 归零，我们带着旧 `Last-Event-ID`
    /// 续流，bridge 回 `studio/replay-gap`。修复前这一帧掉进 `unknownFrames`，
    /// 客户端停在 `.live` 显示**过期**数据 —— 屏幕在说谎却没有任何提示。
    @Test("bridge 说增量有洞 → 重新拉全量快照，而不是贴着旧数据装 live")
    func replayGapForcesReBaseline() async throws {
        let transport = populatedTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)
        #expect(client.snapshotLoadCount == 1)

        transport.push("event: studio/replay-gap\ndata: {\"requested\":37,\"oldest\":120,\"retention\":512}\n\n")
        await waitUntil("重新基线") { client.snapshotLoadCount == 2 }

        #expect(client.link.isLive)
        #expect(client.dataAvailability == .populated)
        // 洞被认领了，不该被当成「不认识的帧」记账了拉倒。
        #expect(client.unknownFrames.contains("studio/replay-gap") == false)
        run.cancel()
        _ = await run.value
    }

    @Test("上游 stream/error → 显式断连并重连，不许记账后继续装 live")
    func streamErrorIsVisibleFailure() async throws {
        let transport = populatedTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)

        transport.push("""
        event: mux
        data: {"type":"stream/error","error":{"code":"internal","message":"boom"}}


        """)
        await waitUntil("链路报失败") { client.lastFailure != nil }

        #expect(client.link.isLive == false)
        #expect(client.lastFailure?.code == "transport")
        // 有过成功快照 → 保留 last-known-good，不清屏、也不谎称空。
        #expect(client.hasSnapshot)
        #expect(client.dataAvailability != .empty)
        run.cancel()
        _ = await run.value
    }

    @Test("mux 里的 session/projection 会真的改标题（曾经整包被丢）")
    func muxProjectionUpdatesTitle() async throws {
        let transport = populatedTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)

        transport.push("""
        event: mux
        data: {"type":"session/projection","sessionId":"s-1","key":"title","value":"新标题","seq":9}


        """)
        await waitUntil("标题投影落地") {
            client.sessionsByID[SessionID("s-1")]?.projections?.title == "新标题"
        }
        run.cancel()
        _ = await run.value
    }

    // MARK: 空态的前提

    @Test("app 刚启动、还没连上 → pending，第一帧不许写「暂无会话」")
    func idleIsPendingNotEmpty() {
        let client = makeClient(transport: blankOnlyTransport())
        #expect(client.link == .idle)
        #expect(client.hasSnapshot == false)
        #expect(client.dataAvailability == .pending)
        #expect(client.dataAvailability != .empty)
    }

    @Test("live + 读懂了的快照 + 零个可显示会话 → 这才是一句正确的「暂无会话」")
    func emptyRequiresLiveLinkAndSnapshot() async throws {
        let transport = blankOnlyTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)

        #expect(client.hasSnapshot)
        #expect(client.sessionsByID.count == 1)      // 会话是存在的……
        #expect(client.visibleSessionCount == 0)     // ……但 blank 不进列表（上游语义）
        #expect(client.dataAvailability == .empty)

        transport.finishHeldStreams()
        _ = await run.value
    }

    @Test("blank 过滤不是 bug：一个 blank 会话不会把 empty 撑成 populated")
    func blankSessionsStayFilteredOut() async throws {
        let transport = blankOnlyTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)
        let workspace = try #require(client.workspaces.first)

        #expect(client.visibleSessions(in: workspace).isEmpty)
        #expect(client.looseSessions().isEmpty)
        #expect(client.dataAvailability == .empty)

        // 会话里发生了第一句话 → 立刻变成有内容（过滤是按 blank，不是按数量）。
        transport.push("id: 7\nevent: session\ndata: " + (try JSONValue.object([
            "sessionId": .string("s-blank"),
            "seq": .number(7),
            "event": .object([
                "type": .string("user/message"),
                "seq": .number(7),
                "time": .number(1_700_000_007),
            ]),
        ]).jsonText()) + "\n\n")
        await waitUntil("会话不再是 blank") { client.dataAvailability == .populated }

        transport.finishHeldStreams()
        _ = await run.value
    }

    // MARK: 失败必须盖住空态

    @Test("live 之后流断了 → 从 empty 翻成 unavailable（同一个零行，两种含义）")
    func liveEmptyBecomesUnavailableWhenStreamDies() async throws {
        let transport = blankOnlyTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)
        #expect(client.dataAvailability == .empty)

        transport.finishHeldStreams()
        _ = await run.value

        #expect(client.visibleSessionCount == 0)          // 行数没变
        #expect(client.dataAvailability != .empty)        // 含义变了
        #expect(client.dataAvailability.failureCode == "stream-ended")
        #expect(client.link.bannerText != nil)
    }

    @Test("surface 进程被杀（连不上端口）→ surface-unreachable，不是 empty")
    func surfaceDeathIsNotEmptiness() async throws {
        let transport = blankOnlyTransport()
        transport.postError = URLError(.cannotConnectToHost)
        let client = makeClient(transport: transport)

        #expect(await client.runOnce())                   // 可重试
        #expect(client.hasSnapshot == false)
        #expect(client.dataAvailability.failureCode == "surface-unreachable")
        #expect(client.dataAvailability.isRetryableFailure == true)
        #expect(client.dataAvailability != .empty)
        #expect(client.lastFailure?.code == "surface-unreachable")
        // 「端口没人应答」与「runtime 没起」的下一步不同，不许压成同一句。
        #expect(client.lastFailure?.code != "runtime-not-running")
    }

    @Test("流中途炸掉（连接被掐）→ 同样归到 surface-unreachable")
    func streamFailureMidFlightIsClassified() async throws {
        let transport = blankOnlyTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)

        transport.finishHeldStreams(throwing: URLError(.networkConnectionLost))
        #expect(await run.value)                          // 值得重试
        #expect(client.dataAvailability.failureCode == "surface-unreachable")
    }

    @Test("超时与「没人接」是两种故障：timed-out 单独成类")
    func timeoutIsItsOwnReason() async throws {
        let transport = blankOnlyTransport()
        transport.postError = URLError(.timedOut)
        let client = makeClient(transport: transport)

        #expect(await client.runOnce())
        #expect(client.dataAvailability.failureCode == "timed-out")
        #expect(client.link.bannerText?.contains("超时") == true)
    }

    @Test("token 失效（401）+ 唯一会话是 blank → 必须说 token，不许说「暂无会话」")
    func unauthorizedNeverLooksLikeEmptiness() async throws {
        let transport = blankOnlyTransport()
        transport.streamStatus = 401
        let client = makeClient(transport: transport)

        #expect(await client.runOnce() == false)          // 换 token 前重试无意义
        #expect(client.hasSnapshot)                       // 快照拿到了，流被拒了
        #expect(client.visibleSessionCount == 0)
        #expect(client.dataAvailability.failureCode == "unauthorized")
        #expect(client.dataAvailability.isRetryableFailure == false)
        #expect(client.dataAvailability != .empty)
        #expect(client.link.bannerText?.contains("token") == true)
    }

    @Test("runtime 没起（bridge.json 不在）→ runtime-not-running，且文案给出启动命令")
    func runtimeNotRunningIsDiagnosable() async throws {
        let client = makeClient(
            transport: blankOnlyTransport(),
            failure: .notFound(path: "/tmp/none/bridge.json")
        )
        #expect(await client.runOnce())
        #expect(client.dataAvailability.failureCode == "runtime-not-running")
        #expect(client.dataAvailability != .empty)
        #expect(client.lastFailure?.remedy?.contains("dsh --profile studio") == true)
    }

    @Test("descriptor 不安全 → unavailable 且标记为不可重试（重试解决不了）")
    func insecureDescriptorIsNotRetryable() async throws {
        let client = makeClient(transport: blankOnlyTransport(), failure: .nonLoopbackHost("0.0.0.0"))
        #expect(await client.runOnce() == false)
        #expect(client.dataAvailability.failureCode == "insecure-descriptor")
        #expect(client.dataAvailability.isRetryableFailure == false)
    }

    @Test("HTTP 5xx → unavailable，且不许因为「返回了 0 行」就说空")
    func serverErrorIsNotEmptiness() async throws {
        let transport = blankOnlyTransport()
        transport.postStatus = 503
        let client = makeClient(transport: transport)

        #expect(await client.runOnce())
        #expect(client.hasSnapshot == false)
        #expect(client.dataAvailability.isUnavailable)
        #expect(client.dataAvailability != .empty)
        #expect(client.link.bannerText?.contains("HTTP 503") == true)
    }

    // MARK: 协议漂移 —— 最容易被静默吞掉的一类

    @Test("上游把 items 改了名 → protocol-broken，而不是「零个工作区、暂无会话」")
    func protocolDriftIsNeverEmptiness() async throws {
        let transport = FakeTransport(rpcValues: [
            // 契约漂移的样子：形状变了，HTTP 还是 200。
            RPCMethod.workspaceList.rawValue: .object(["workspaces": .array([])]),
            RPCMethod.sessionList.rawValue: sessions([]),
        ])
        let client = makeClient(transport: transport)

        #expect(await client.runOnce())                   // 版本不一致可能马上被修好
        #expect(client.hasSnapshot == false)              // 没有「成功」的快照
        #expect(client.workspaces.isEmpty)                // 确实一行都没有……
        #expect(client.dataAvailability != .empty)        // ……但绝不许说「暂无会话」
        #expect(client.dataAvailability.failureCode == "protocol-broken")
        #expect(client.link.bannerText?.contains("读不懂") == true)
        // 读不懂 workspace.list 就不该继续假装拿到了会话。
        #expect(transport.posts.map(\.method) == ["workspace.list"])
    }

    @Test("读不懂新回答时，上一份已知良好的投影不许被清空")
    func protocolDriftKeepsLastKnownGoodData() async throws {
        let transport = populatedTransport()
        let clock = TestClock()
        let client = makeClient(transport: transport, clock: clock)

        let run = await goLive(client, transport)
        #expect(client.dataAvailability == .populated)
        transport.finishHeldStreams()
        _ = await run.value

        // runtime 被换成了另一个版本，同时断得够久必须重拉全量。
        transport.holdStreamOpen = false
        transport.setRPCValue(.object(["workspaces": .array([])]), for: .workspaceList)
        clock.advance(by: 600)
        #expect(await client.runOnce())

        #expect(client.workspaces.count == 1)             // 旧事实还在
        // 有行就继续画行，但标成 `.stale`：读不懂新回答之后，屏幕上那份是
        // 「上一次读懂的样子」，不是现状（G-13）。
        #expect(client.dataAvailability.hasRows)
        #expect(client.dataAvailability.isCurrent == false)
        #expect(client.lastFailure?.code == "protocol-broken")
        #expect(client.snapshotLoadCount == 1)            // 失败的快照不计数
    }

    @Test("已经看见过的会话在重连期间留在屏幕上（清空列表是另一种撒谎），但标成过期")
    func knownRowsSurviveDisconnect() async throws {
        let transport = populatedTransport()
        let client = makeClient(transport: transport)
        let run = await goLive(client, transport)
        #expect(client.dataAvailability == .populated)

        transport.finishHeldStreams(throwing: URLError(.cannotConnectToHost))
        _ = await run.value

        #expect(client.dataAvailability.hasRows)          // 行留着
        #expect(client.dataAvailability.isCurrent == false) // 但不当现状
        #expect(client.link.bannerText?.contains("数据通道") == true)
        #expect(client.lastFailure?.code == "surface-unreachable")
    }

    // MARK: 退避 —— 有节制的重试

    @Test("自动重连按指数退避并封顶，不会狂打 runtime")
    func backoffGrowsAndCaps() async throws {
        let transport = blankOnlyTransport()
        // 连 4 次「开了流就断」，第 5 次 401 让循环自然停下（不可重试）。
        transport.enqueueStreamStatuses([200, 200, 200, 200])
        transport.streamStatus = 401
        let recorder = SleepRecorder()
        let client = makeClient(
            transport: transport,
            policy: ResumePolicy(minimumBackoff: 0.5, maximumBackoff: 2),
            sleeper: recorder.sleeper
        )

        client.start()
        await waitUntil("循环遇到不可重试的失败后停止") {
            client.dataAvailability.failureCode == "unauthorized"
        }

        #expect(recorder.delays == [0.5, 1, 2, 2])        // 递增且封顶
        #expect(client.reconnectAttempt == 4)
        #expect(client.nextRetryDelay == nil)             // 已经不在等了
        client.stop()
    }

    @Test("「连上就断」的 runtime 不会把退避计数刷回 0（否则退避形同虚设）")
    func flappingRuntimeDoesNotResetBackoff() async throws {
        let transport = blankOnlyTransport()
        transport.enqueueStreamStatuses([200, 200, 200, 200])
        transport.streamStatus = 401
        let recorder = SleepRecorder()
        // 时钟不动 → 每轮连接都活不满 stabilityWindow。
        let client = makeClient(
            transport: transport,
            clock: TestClock(),
            policy: ResumePolicy(minimumBackoff: 1, maximumBackoff: 100, stabilityWindow: 5),
            sleeper: recorder.sleeper
        )

        client.start()
        await waitUntil("循环停止") { client.dataAvailability.failureCode == "unauthorized" }

        #expect(recorder.delays == [1, 2, 4, 8])          // 不是 [1, 1, 1, 1]
        client.stop()
    }

    @Test("站稳过一段时间的连接才把退避归零")
    func stableConnectionResetsBackoff() async throws {
        let transport = blankOnlyTransport()
        transport.enqueueStreamStatuses([200, 200, 200, 200])
        transport.streamStatus = 401
        let recorder = SleepRecorder()
        // 每次读钟前进 10s → 每轮连接都活过了 5s 的稳定窗口。
        let client = makeClient(
            transport: transport,
            clock: TestClock(autoAdvancingBy: 10),
            policy: ResumePolicy(minimumBackoff: 1, maximumBackoff: 100, stabilityWindow: 5),
            sleeper: recorder.sleeper
        )

        client.start()
        await waitUntil("循环停止") { client.dataAvailability.failureCode == "unauthorized" }

        #expect(recorder.delays == [1, 1, 1, 1])          // 每轮都站稳过 → 每次都从头退避
        #expect(client.reconnectAttempt == 1)
        client.stop()
    }

    // MARK: 手动重试

    @Test("手动重试是不可重试失败的唯一复活路径（换了 token 之后）")
    func manualRetryRevivesTerminalFailure() async throws {
        let transport = blankOnlyTransport()
        transport.streamStatus = 401
        let recorder = SleepRecorder()
        let client = makeClient(transport: transport, sleeper: recorder.sleeper)

        client.start()
        await waitUntil("停在 unauthorized") { client.dataAvailability.failureCode == "unauthorized" }
        #expect(recorder.delays.isEmpty)                  // 不可重试 → 一次都没退避重试

        // 用户重启了 dsh：token 换了一把，会话里也真的有内容了。
        transport.streamStatus = 200
        transport.setRPCValue(sessions([(id: "s-blank", blank: false)]), for: .sessionList)
        transport.holdStreamOpen = true
        client.retryNow()
        await waitUntil("手动重试连上") { client.link.isLive }

        #expect(client.manualRetryCount == 1)
        #expect(client.reconnectAttempt == 0)             // 用户等不了指数退避
        #expect(client.dataAvailability == .populated)
        #expect(client.lastFailure?.code == "unauthorized")  // 留痕：刚才为什么空了一下

        client.stop()
        transport.finishHeldStreams()
    }

    @Test("refreshSnapshot 失败会记在链路状态上，调用方 try? 也吞不掉")
    func refreshSnapshotFailureIsRecorded() async throws {
        let transport = blankOnlyTransport()
        transport.postStatus = 500
        let client = makeClient(transport: transport)

        try? await client.refreshSnapshot()               // 故意像离屏渲染那样吞掉

        #expect(client.dataAvailability.isUnavailable)
        #expect(client.dataAvailability != .empty)
        #expect(client.lastFailure?.code == "transport")
    }
}

// MARK: - 分类本身的可诊断性

@Suite("失败原因：分类即可诊断性")
struct DisconnectReasonDiagnosticsTests {
    private let all: [DisconnectReason] = [
        .runtimeNotRunning("/tmp/bridge.json"),
        .surfaceUnreachable("connection refused"),
        .unauthorized,
        .insecureDescriptor("world-writable"),
        .timedOut("15s"),
        .protocolBroken("workspace.list: missing items"),
        .transport("HTTP 503"),
        .streamEnded,
        .cancelled,
    ]

    @Test("每个原因都有稳定且互不相同的 code（日志与测试靠它，不靠中文文案）")
    func codesAreUniqueAndStable() {
        let codes = all.map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(codes.allSatisfy { !$0.isEmpty && !$0.contains(" ") })
    }

    @Test("除主动取消外，每个原因都必须给出「是什么」和「下一步」")
    func everyFailureExplainsItselfAndTheNextStep() {
        for reason in all where reason != .cancelled {
            #expect(reason.headline?.isEmpty == false, "\(reason.code) 缺少 headline")
            #expect(reason.remedy?.isEmpty == false, "\(reason.code) 缺少 remedy")
        }
        // 主动取消不是故障：不该在正在关闭的界面上画告警。
        #expect(DisconnectReason.cancelled.headline == nil)
        #expect(RuntimeLinkState.disconnected(reason: .cancelled, since: Date()).bannerText == nil)
    }

    @Test("失败文案里绝不许出现「暂无」——那是关于数据的断言，不是关于链路的")
    func failureCopyNeverClaimsEmptiness() {
        for reason in all {
            #expect(reason.headline?.contains("暂无") != true)
            #expect(reason.remedy?.contains("暂无") != true)
            #expect(reason.headline?.contains("没有会话") != true)
        }
    }

    /// 「说人话」是可以被机器守住的一条：**原始错误串不许进 UI，也不许丢**。
    ///
    /// 侧栏第一版失败态长这样：「端口上没有应答（The operation couldn't be
    /// completed. (NSURLErrorDomain error -1004.)）」—— 离屏渲染的 PNG 一眼就看
    /// 出它把一句人话变回了一行栈迹。但细节本身有诊断价值，所以它该在
    /// `description`（日志读的那一栏）里，不在 `remedy`（人读的那一栏）里。
    @Test("remedy 是人话：不夹带 URLError 原始描述，但日志里不许丢")
    func remedyIsHumanReadableWhileLogsKeepTheDetail() {
        let raw = "The operation couldn’t be completed. (NSURLErrorDomain error -1004.)"
        for reason in [DisconnectReason.surfaceUnreachable(raw), .timedOut(raw)] {
            #expect(reason.remedy?.contains("NSURLErrorDomain") != true, "\(reason.code) 把栈迹画给了用户")
            #expect(reason.remedy?.isEmpty == false)
            #expect(reason.description.contains("NSURLErrorDomain"), "\(reason.code) 把细节丢了，日志无从排查")
        }
    }

    @Test("可重试性按「重试有没有意义」划分，不按严重程度")
    func retryabilityMatchesRemedy() {
        #expect(DisconnectReason.unauthorized.isRetryable == false)
        #expect(DisconnectReason.insecureDescriptor("x").isRetryable == false)
        #expect(DisconnectReason.runtimeNotRunning("x").isRetryable)
        #expect(DisconnectReason.surfaceUnreachable("x").isRetryable)
        #expect(DisconnectReason.timedOut("x").isRetryable)
        // 读不懂通常是版本正在被换，值得再试一次（文案会说清是「读不懂」）。
        #expect(DisconnectReason.protocolBroken("x").isRetryable)
    }

    @Test("退避是纯函数：指数增长、封顶、永不放弃")
    func backoffIsPureAndBounded() {
        let policy = ResumePolicy(minimumBackoff: 0.5, maximumBackoff: 8)
        #expect((1...12).map { policy.backoff(attempt: $0) } == [0.5, 1, 2, 4, 8, 8, 8, 8, 8, 8, 8, 8])
        #expect(policy.backoff(attempt: 0) == 0.5)        // 越界不许算出 0 或负数
        #expect(policy.backoff(attempt: 1_000_000) == 8)  // 也不许溢出成 inf
    }
}
