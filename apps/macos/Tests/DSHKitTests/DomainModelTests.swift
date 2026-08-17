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

    @Test("响应解包：{ok,value} / {ok:false,error} / 裸值")
    func unwrapsReplies() throws {
        let wrapped = try RPCReply.unwrap(.object(["ok": .bool(true), "value": .object(["items": .array([])])]))
        #expect(wrapped["items"]?.arrayValue?.isEmpty == true)

        let bare = try RPCReply.unwrap(.object(["items": .array([])]))
        #expect(bare["items"] != nil)

        #expect(throws: RPCFault(code: "not_found", message: "no such session")) {
            try RPCReply.unwrap(.object([
                "ok": .bool(false),
                "error": .object(["code": .string("not_found"), "message": .string("no such session")]),
            ]))
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
