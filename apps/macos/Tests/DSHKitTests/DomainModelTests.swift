import Testing
import Foundation
@testable import DSHKit

@Suite("领域 tagged union 必须有 unknown 兜底（bridge-contract.md §3）")
struct DomainUnionTests {
    @Test("未知 session/event 类型降级为 unknown，不崩、不丢原文")
    func unknownSessionEventKeepsPayload() throws {
        let record = try JSONValue.object([
            "type": .string("assistant/hologram"),
            "seq": .number(41),
            "time": .number(1_700_000_000),
            "data": .object(["frames": .number(3)]),
        ]).decoded(as: SessionEventRecord.self)

        guard case .unknown(let raw) = record.payload else {
            Issue.record("expected unknown payload, got \(record.payload)")
            return
        }
        #expect(record.payload.unknownType == "assistant/hologram")
        #expect(raw["data"]?["frames"]?.intValue == 3)
    }

    @Test("已知事件类型解出结构化载荷")
    func knownSessionEvents() {
        #expect(SessionEventPayload(type: "turn/start", data: .null) == .turnStart)
        #expect(SessionEventPayload(type: "turn/end", data: .null) == .turnEnd)
        #expect(SessionEventPayload(type: "user/message", data: .object(["text": .string("hi")]))
            == .userMessage(text: "hi"))
        #expect(SessionEventPayload(type: "assistant/chunk", data: .object(["delta": .string("ab")]))
            == .assistantChunk(delta: "ab"))
        #expect(SessionEventPayload(type: "tool/call", data: .object(["name": .string("bash"), "callId": .string("c1")]))
            == .toolCall(name: "bash", callID: "c1"))
        // 上游 message.content 数组形态也能取到文本。
        #expect(SessionEventPayload(
            type: "assistant/message",
            data: .object(["message": .object(["content": .array([.object(["text": .string("a")]), .object(["text": .string("b")])])])])
        ) == .assistantMessage(text: "ab"))
    }

    @Test("未知 host frame 类型降级为 unknown")
    func unknownHostFrame() {
        let frame = HostFrame(.object(["type": .string("host/quantum-tunnel")]))
        guard case .unknown = frame else {
            Issue.record("expected unknown host frame")
            return
        }
        // 字段缺失的已知类型也走兜底，而不是造一个半截状态。
        guard case .unknown = HostFrame(.object(["type": .string("host/session-status")])) else {
            Issue.record("expected unknown for malformed session-status")
            return
        }
    }

    @Test("已知 host frame 解码")
    func knownHostFrames() {
        #expect(HostFrame(.object([
            "type": .string("host/session-status"),
            "sessionId": .string("s-1"),
            "running": .bool(true),
        ])) == .sessionStatus(SessionID("s-1"), running: true))

        #expect(HostFrame(.object([
            "type": .string("host/archived-sessions-changed"),
            "archivedSessionIds": .array([.string("s-9")]),
        ])) == .archivedSessionsChanged([SessionID("s-9")]))

        let workspace = HostFrame(.object([
            "type": .string("host/workspace-changed"),
            "workspace": .object([
                "workspaceId": .string("w-1"),
                "path": .string("/tmp/demo"),
                "title": .string("demo"),
                "sessionIds": .array([.string("s-1")]),
                "createdAt": .string("2025-01-01"),
                "updatedAt": .string("2025-01-02"),
            ]),
        ]))
        guard case .workspaceChanged(let view) = workspace else {
            Issue.record("expected workspaceChanged")
            return
        }
        #expect(view.workspaceId == WorkspaceID("w-1"))
        #expect(view.sessionIds == [SessionID("s-1")])
    }

    @Test("bridge 真实发的 event 名都被听见：mux / studio/replay-gap（G-12）")
    func hearsWhatTheBridgeActuallySends() {
        // bridge 把 mux 的非 session/event 帧命名为 `mux` 并原样转发，
        // 投影就在里面 —— 曾经整包掉进 .unknown，于是标题永不更新。
        guard case .projection(let projection) = StreamFrame.decode(eventName: "mux", data: .object([
            "type": .string("session/projection"),
            "sessionId": .string("s-1"),
            "key": .string("title"),
            "value": .string("重命名之后的标题"),
            "seq": .number(42),
        ])) else {
            Issue.record("mux 里的 session/projection 必须被解出来")
            return
        }
        #expect(projection.key == "title")
        #expect(projection.seq == 42)

        // 上游明说流坏了：必须是失败，不是 unknown。
        guard case .streamError(let fault) = StreamFrame.decode(eventName: "mux", data: .object([
            "type": .string("stream/error"),
            "error": .object(["code": .string("internal"), "message": .string("boom")]),
        ])) else {
            Issue.record("stream/error 必须解成 streamError")
            return
        }
        #expect(fault.code == "internal")

        // bridge 明说增量有洞 → 必须解成 replayGap，让客户端重新基线。
        guard case .replayGap(let requested, let oldest) = StreamFrame.decode(
            eventName: "studio/replay-gap",
            data: .object(["requested": .number(37), "oldest": .number(120), "retention": .number(512)])
        ) else {
            Issue.record("studio/replay-gap 必须被听见")
            return
        }
        #expect(requested == 37)
        #expect(oldest == 120)

        // mux 里我们不建模的家族仍然记账降级，但名字要带出内层 type 便于排查。
        guard case .unknown(let name, _) = StreamFrame.decode(eventName: "mux", data: .object([
            "type": .string("approval/requested"), "sessionId": .string("s-1"),
        ])) else {
            Issue.record("expected unknown")
            return
        }
        #expect(name == "mux:approval/requested")
    }

    @Test("未知 SSE event 名不丢弃、不崩")
    func unknownStreamFrameName() {
        let frame = StreamFrame.decode(eventName: "telemetry", data: .object(["a": .number(1)]))
        guard case .unknown(let name, _) = frame else {
            Issue.record("expected unknown frame")
            return
        }
        #expect(name == "telemetry")
        // `event: session` 但 data 形状不对 → 同样降级，而不是 try!。
        guard case .unknown(let sessionName, _) = StreamFrame.decode(eventName: "session", data: .object(["nope": .bool(true)])) else {
            Issue.record("expected unknown for malformed session frame")
            return
        }
        #expect(sessionName == "session")
    }

    @Test("SessionOrigin 未知值兜底")
    func unknownOrigin() throws {
        let summary = try JSONValue.object([
            "sessionId": .string("s-1"),
            "updatedAt": .number(1),
            "running": .bool(false),
            "blank": .bool(false),
            "origin": .string("cron"),
        ]).decoded(as: SessionSummary.self)
        #expect(summary.origin == .unknown(.string("cron")))

        let subagent = try JSONValue.string("subagent").decoded(as: SessionOrigin.self)
        #expect(subagent == .subagent)
    }

    @Test("会话显示名：标题投影 → cwd 末段 → 短 id")
    func displayTitleFallbacks() {
        let titled = SessionSummary(
            sessionId: SessionID("0123456789abcdef"),
            updatedAt: 0, running: false, blank: false,
            cwd: "/Users/me/code/dsh",
            projections: SessionProjections(asOfSeq: 3, values: ["title": .string("重构侧栏")])
        )
        #expect(titled.displayTitle == "重构侧栏")

        let cwdOnly = SessionSummary(
            sessionId: SessionID("0123456789abcdef"),
            updatedAt: 0, running: false, blank: false, cwd: "/Users/me/code/dsh"
        )
        #expect(cwdOnly.displayTitle == "dsh")

        let bare = SessionSummary(sessionId: SessionID("0123456789abcdef"), updatedAt: 0, running: false, blank: false)
        #expect(bare.displayTitle == "01234567")
    }

    @Test("workspace.list 缺 archivedSessionIds 时不报错")
    func workspaceListTolerantDecoding() throws {
        let value = try JSONValue.object(["items": .array([])]).decoded(as: WorkspaceListValue.self)
        #expect(value.items.isEmpty)
        #expect(value.archivedSessionIds.isEmpty)
    }

    @Test("workspace.list 缺 items 必须抛错——不许把上游漂移解成「零个工作区」")
    func workspaceListRejectsMissingItems() throws {
        // 上游把 `items` 改名成 `workspaces`（或多包一层）时的样子。
        // 曾经这里 `decodeIfPresent ?? []`，于是协议漂移与「你真的没有工作区」
        // 长得一模一样，侧栏理直气壮地写「暂无会话」。宽容解码在**列表主体**上
        // 就是静默降级。
        #expect(throws: (any Error).self) {
            _ = try JSONValue.object(["workspaces": .array([])]).decoded(as: WorkspaceListValue.self)
        }
        #expect(throws: (any Error).self) {
            _ = try JSONValue.object([:]).decoded(as: WorkspaceListValue.self)
        }
    }

    @Test("session.list 缺 items 同样抛错")
    func sessionListRejectsMissingItems() throws {
        #expect(throws: (any Error).self) {
            _ = try JSONValue.object(["sessions": .array([])]).decoded(as: SessionListValue.self)
        }
    }

    @Test("投影表是开放集合：未知 key 原样保留")
    func projectionsKeepUnknownKeys() throws {
        let block = try JSONValue.object([
            "asOfSeq": .number(7),
            "values": .object(["title": .string("t"), "plugin.badge": .number(2)]),
        ]).decoded(as: SessionProjections.self)
        #expect(block.title == "t")
        #expect(block.values["plugin.badge"]?.intValue == 2)
    }
}

@Suite("RPC 转发面")
struct RPCTests {
    @Test("studio.* 不许走官方 /rpc 转发面")
    func studioMethodsAreNotForwardable() {
        #expect(RPCMethod.sessionList.isForwardable)
        #expect(RPCMethod.workspaceArchiveSession.isForwardable)
        #expect(!RPCMethod(rawValue: "studio.slotProbe").isForwardable)
        #expect(!RPCMethod(rawValue: "").isForwardable)
        #expect(!RPCMethod(rawValue: "nonsense").isForwardable)
    }

    @Test("方法名全部对齐上游 RpcMethodMap 的命名形状")
    func methodNames() {
        #expect(RPCMethod.sessionCreate.rawValue == "session.create")
        #expect(RPCMethod.workspaceList.rawValue == "workspace.list")
        #expect(RPCMethod.workspaceArchiveSession.rawValue == "workspace.archiveSession")
    }

    @Test("响应解包：官方 server-response 信封是线上唯一形状")
    func unwrapsOfficialEnvelope() throws {
        // 逐字取自真机 `POST /rpc {"method":"workspace.list"}` 的回答。
        let live = try JSONValue.decode(Data("""
        {"type":"server-response","rpcId":"84ebdbd1-aa94-456c-985b-cff19a71b681",
         "result":{"ok":true,"value":{"items":[{"workspaceId":"f42ee878","path":"/Users/bytedance/Workspace",
         "title":"Workspace","sessionIds":["session-d7beff90"],"createdAt":"","updatedAt":""}],
         "archivedSessionIds":[]}}}
        """.utf8))
        let value = try RPCReply.unwrap(live)
        // 解包结果必须是**业务值**，不是信封：这正是 G-11 当年错的地方。
        #expect(value["items"]?.arrayValue?.count == 1)
        #expect(value["type"] == nil)
        let list = try value.decoded(as: WorkspaceListValue.self)
        #expect(list.items.first?.path == "/Users/bytedance/Workspace")
    }

    @Test("响应解包：裸 result 本体 / ok:false 业务错误")
    func unwrapsResultBody() throws {
        let wrapped = try RPCReply.unwrap(.object(["ok": .bool(true), "value": .object(["items": .array([])])]))
        #expect(wrapped["items"]?.arrayValue?.isEmpty == true)

        // void 业务结果：信封里根本没有 value（上游明写）→ 空对象。
        let void = try RPCReply.unwrap(.object([
            "type": .string("server-response"),
            "rpcId": .string("x"),
            "result": .object(["ok": .bool(true)]),
        ]))
        #expect(void == .object([:]))

        #expect(throws: RPCFault(code: "not_found", message: "no such session")) {
            try RPCReply.unwrap(.object([
                "type": .string("server-response"),
                "rpcId": .string("x"),
                "result": .object([
                    "ok": .bool(false),
                    "error": .object(["code": .string("not_found"), "message": .string("no such session")]),
                ]),
            ]))
        }
    }

    @Test("响应解包：读不懂的形状必须抛 EnvelopeError，绝不当作业务值放行（G-11）")
    func refusesToGuess() throws {
        // 裸值兜底是这个 bug 的载体：`{items:…}` 没有 ok/type，说明我们对
        // 这条响应的结构一无所知，放行等于让上层拿信封当数据。
        #expect(throws: RPCReply.EnvelopeError.self) {
            try RPCReply.unwrap(.object(["items": .array([])]))
        }
        // 信封在，但 result 缺失/形状不对。
        #expect(throws: RPCReply.EnvelopeError.self) {
            try RPCReply.unwrap(.object(["type": .string("server-response"), "rpcId": .string("x")]))
        }
        #expect(throws: RPCReply.EnvelopeError.self) {
            try RPCReply.unwrap(.object([
                "type": .string("server-response"), "rpcId": .string("x"),
                "result": .object(["value": .object([:])]),
            ]))
        }
        // 换了一种 type：也许是别的信封，反正不是我们认识的。
        #expect(throws: RPCReply.EnvelopeError.self) {
            try RPCReply.unwrap(.object(["type": .string("server-request"), "result": .object(["ok": .bool(true)])]))
        }
        #expect(throws: RPCReply.EnvelopeError.self) {
            try RPCReply.unwrap(.array([]))
        }
    }

    @Test("请求体编码为 { method, params }")
    func encodesRequestBody() throws {
        let value = try JSONValue(encoding: RPCRequestBody(method: .sessionList, params: EmptyParams()))
        #expect(value["method"]?.stringValue == "session.list")
        #expect(value["params"] == .object([:]))
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("整数往回写不带小数点（seq / priority 不能变成 1.0）")
    func keepsIntegersExact() throws {
        let text = try JSONValue.object(["seq": .number(128), "priority": .number(-1)]).jsonText()
        #expect(text == #"{"priority":-1,"seq":128}"#)
    }

    @Test("round trip 保持结构与顺序无关的相等性")
    func roundTrips() throws {
        let value = JSONValue.object([
            "a": .array([1, "two", true, .null]),
            "b": .object(["c": 3.5]),
        ])
        #expect(try JSONValue.decode(json: try value.jsonText()) == value)
    }

    @Test("depth 是不可信输入的护栏")
    func computesDepth() {
        #expect(JSONValue.string("x").depth == 1)
        #expect(JSONValue.object(["a": .object(["b": .string("c")])]).depth == 3)
        #expect(JSONValue.array([.array([.array([1])])]).depth == 4)
    }
}
