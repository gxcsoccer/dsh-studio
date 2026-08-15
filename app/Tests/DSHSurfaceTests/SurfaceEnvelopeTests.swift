import DSHKit
import Foundation
import Testing

@testable import DSHSurface

struct SurfaceEnvelopeTests {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    @Test("request 的线上形状")
    func requestShape() throws {
        let frame = SurfaceFrame.request(
            id: "s-1",
            method: "openWorkspace",
            payload: .object(["path": .string("/tmp/proj")])
        )
        let wire = try decoder.decode(JSONValue.self, from: encoder.encode(frame))

        #expect(wire["v"] == .number(1))
        #expect(wire["type"]?.stringValue == "req")
        #expect(wire["id"]?.stringValue == "s-1")
        #expect(wire["method"]?.stringValue == "openWorkspace")
        #expect(wire["payload"]?["path"]?.stringValue == "/tmp/proj")
    }

    @Test("成功响应和失败响应都回显 id")
    func responseShape() throws {
        let ok = try decoder.decode(
            JSONValue.self,
            from: encoder.encode(SurfaceFrame.response(id: "s-1", value: .object(["sessionId": .string("a")])))
        )
        #expect(ok["type"]?.stringValue == "res")
        #expect(ok["id"]?.stringValue == "s-1")
        #expect(ok["ok"] == .bool(true))
        #expect(ok["value"]?["sessionId"]?.stringValue == "a")

        let fail = try decoder.decode(
            JSONValue.self,
            from: encoder.encode(SurfaceFrame.failure(id: "s-1", error: "nope"))
        )
        #expect(fail["ok"] == .bool(false))
        #expect(fail["error"]?.stringValue == "nope")
    }

    @Test("事件没有 id")
    func eventShape() throws {
        let wire = try decoder.decode(
            JSONValue.self,
            from: encoder.encode(SurfaceFrame.event(method: "ready"))
        )
        #expect(wire["type"]?.stringValue == "evt")
        #expect(wire["method"]?.stringValue == "ready")
        #expect(wire["id"] == nil)
    }

    @Test("dispatch 脚本把 JSON 当作 JS 表达式嵌进去")
    func dispatchScript() throws {
        let script = try SurfaceScript.dispatch(SurfaceFrame.event(method: "ready"))
        #expect(script.hasPrefix(SurfaceScript.callPrefix))
        #expect(script.hasSuffix(SurfaceScript.callSuffix))

        let json = try #require(SurfaceScript.frameJSON(in: script))
        let frame = try decoder.decode(SurfaceFrame.self, from: Data(json.utf8))
        #expect(frame.type == .evt)
        #expect(frame.method == "ready")
    }

    @Test("旧的只收尾 ) 的脚本解析不出来，避免再把 Promise 当返回值")
    func frameJSONRejectsLegacySuffix() throws {
        let frame = SurfaceFrame.event(method: "ready")
        let json = String(data: try encoder.encode(frame), encoding: .utf8)!
        let legacy = "\(SurfaceScript.callPrefix)\(json))"
        #expect(SurfaceScript.frameJSON(in: legacy) == nil)
        #expect(SurfaceScript.frameJSON(in: "alert(1)") == nil)
    }

    @Test("新会话落在当前行所属的工作区")
    func inferredWorkspaceFollowsCurrentSession() {
        let catalog = SurfaceCatalog(
            currentSessionId: "s-2",
            workspaces: [
                group(id: "ws-a", sessions: ["s-1"]),
                group(id: "ws-b", sessions: ["s-2", "s-3"]),
            ],
            ungrouped: []
        )
        #expect(catalog.inferredWorkspaceId == "ws-b")
    }

    @Test("命令面板按标题和工作区过滤，跳过草稿")
    func catalogHitsSkipBlanksAndMatch() {
        let catalog = SurfaceCatalog(
            currentSessionId: "draft",
            workspaces: [
                group(id: "ws-a", title: "Workspace", sessions: [
                    ("talk", "pong", false),
                    ("draft", "新会话", true),
                ]),
            ],
            ungrouped: [
                SurfaceSessionRow(
                    sessionId: "probe",
                    title: "Run bash probe",
                    blank: false,
                    running: false,
                    updatedAt: 0
                ),
            ]
        )
        #expect(catalog.hits(matching: "pong").map(\.session.sessionId) == ["talk"])
        #expect(catalog.hits(matching: "probe").map(\.session.sessionId) == ["probe"])
        #expect(catalog.hits(matching: "").isEmpty)
    }

    @Test("最近按更新时间倒序，跳过草稿")
    func catalogRecentsSkipBlanksAndSort() {
        let catalog = SurfaceCatalog(
            currentSessionId: "draft",
            workspaces: [
                SurfaceWorkspaceGroup(
                    workspaceId: "ws-a",
                    title: "Workspace",
                    path: "/tmp/ws-a",
                    sessions: [
                        SurfaceSessionRow(sessionId: "old", title: "old", blank: false, running: false, updatedAt: 1),
                        SurfaceSessionRow(sessionId: "draft", title: "新会话", blank: true, running: false, updatedAt: 9),
                        SurfaceSessionRow(sessionId: "new", title: "new", blank: false, running: false, updatedAt: 5),
                    ]
                ),
            ],
            ungrouped: [
                SurfaceSessionRow(sessionId: "mid", title: "mid", blank: false, running: false, updatedAt: 3),
            ]
        )
        #expect(catalog.recents(limit: 8).map(\.session.sessionId) == ["new", "mid", "old"])
        #expect(catalog.recents(limit: 1).map(\.session.sessionId) == ["new"])
    }

    @Test("正文命中并入已有行，而不是再占一行")
    func catalogHitsAttachContentSnippet() {
        let catalog = SurfaceCatalog(
            currentSessionId: "talk",
            workspaces: [
                group(id: "ws-a", title: "Workspace", sessions: [
                    ("talk", "pong", false),
                    ("other", "目录内容查看", false),
                ]),
            ],
            ungrouped: []
        )
        let hits = catalog.hits(
            matching: "pong",
            content: [
                SurfaceSearchSnippet(sessionId: "talk", snippet: "Reply with exactly: pong"),
                SurfaceSearchSnippet(sessionId: "other", snippet: "pong in the log"),
            ]
        )
        #expect(hits.map(\.session.sessionId) == ["talk", "other"])
        #expect(hits[0].snippet == "Reply with exactly: pong")
        #expect(hits[1].snippet == "pong in the log")
        #expect(
            catalog.hits(
                matching: "ghost",
                content: [SurfaceSearchSnippet(sessionId: "archived", snippet: "gone")]
            ).isEmpty
        )
    }

    @Test("没有当前行时新会话落在第一个工作区")
    func inferredWorkspaceFallsBackToFirstGroup() {
        let catalog = SurfaceCatalog(
            currentSessionId: nil,
            workspaces: [group(id: "ws-a", sessions: ["s-1"])],
            ungrouped: []
        )
        #expect(catalog.inferredWorkspaceId == "ws-a")
    }

    @Test("当前行在未分组时，新会话仍落到第一个工作区")
    func inferredWorkspaceSkipsUngroupedCurrent() {
        let catalog = SurfaceCatalog(
            currentSessionId: "orphan",
            workspaces: [group(id: "ws-a", sessions: ["s-1"])],
            ungrouped: [
                SurfaceSessionRow(
                    sessionId: "orphan",
                    title: "无家可归",
                    blank: false,
                    running: false,
                    updatedAt: 1
                ),
            ]
        )
        #expect(catalog.inferredWorkspaceId == "ws-a")
        #expect(catalog.lookup("orphan")?.workspace == "未分组")
        #expect(catalog.lookup("missing") == nil)
    }

    @Test("工作区名命中该组全部非草稿；空白和大小写不敏感；limit 截断")
    func catalogHitsWorkspaceCaseLimit() {
        let catalog = SurfaceCatalog(
            currentSessionId: "talk",
            workspaces: [
                group(id: "ws-a", title: "Alpha Lab", sessions: [
                    ("talk", "pong", false),
                    ("draft", "新会话", true),
                    ("note", "纪要", false),
                ]),
                group(id: "ws-b", title: "Other", sessions: [
                    ("other", "pong two", false),
                ]),
            ],
            ungrouped: []
        )
        #expect(catalog.hits(matching: "  ALPHA  ").map(\.session.sessionId) == ["talk", "note"])
        #expect(catalog.hits(matching: "PONG").map(\.session.sessionId) == ["talk", "other"])
        #expect(catalog.hits(matching: "pong", limit: 1).map(\.session.sessionId) == ["talk"])
        #expect(catalog.lookup("talk")?.workspace == "Alpha Lab")
    }

    private func group(id: String, sessions: [String]) -> SurfaceWorkspaceGroup {
        group(id: id, title: id, sessions: sessions.map { ($0, $0, false) })
    }

    private func group(
        id: String,
        title: String,
        sessions: [(String, String, Bool)]
    ) -> SurfaceWorkspaceGroup {
        SurfaceWorkspaceGroup(
            workspaceId: id,
            title: title,
            path: "/tmp/\(id)",
            sessions: sessions.map {
                SurfaceSessionRow(
                    sessionId: $0.0,
                    title: $0.1,
                    blank: $0.2,
                    running: false,
                    updatedAt: 0
                )
            }
        )
    }
}
