import DSHKit
import Foundation
import Testing

@testable import DSHSurface

@MainActor
final class ScriptedPage: SurfaceTransport {
    private(set) var scripts: [String] = []
    var onEvaluate: ((SurfaceFrame) -> Void)?

    func evaluate(_ javascript: String) async throws {
        scripts.append(javascript)
        let frame = try Self.frame(in: javascript)
        onEvaluate?(frame)
    }

    static func frame(in script: String) throws -> SurfaceFrame {
        guard let json = SurfaceScript.frameJSON(in: script) else {
            throw SurfaceError.unexpected("not a dispatch script")
        }
        return try JSONDecoder().decode(SurfaceFrame.self, from: Data(json.utf8))
    }
}

@MainActor
struct SurfaceBridgeTests {
    @Test("ready 之前的请求会等到 ready 再发出")
    func queuesUntilReady() async throws {
        let page = ScriptedPage()
        let bridge = SurfaceBridge()
        bridge.attach(page)

        var sent: SurfaceFrame?
        page.onEvaluate = { sent = $0 }

        let task = Task { try await bridge.openWorkspace(path: "/tmp/proj") }
        await Task.yield()
        #expect(page.scripts.isEmpty)

        bridge.receive(SurfaceFrame.event(method: "ready").asObject())
        for _ in 0..<40 where sent == nil {
            await Task.yield()
        }

        let request = try #require(sent)
        #expect(request.type == .req)
        #expect(request.method == "openWorkspace")
        #expect(request.payload?["path"]?.stringValue == "/tmp/proj")

        let id = try #require(request.id)
        bridge.receive(
            SurfaceFrame.response(
                id: id,
                value: .object(["workspaceId": .string("ws"), "sessionId": .string("s1")])
            ).asObject()
        )

        let result = try await task.value
        #expect(result.workspaceId == "ws")
        #expect(result.sessionId == "s1")
    }

    @Test("页面回的业务错误变成 SurfaceError.remote")
    func remoteError() async throws {
        let page = ScriptedPage()
        let bridge = SurfaceBridge()
        bridge.attach(page)
        bridge.receive(SurfaceFrame.event(method: "ready").asObject())

        page.onEvaluate = { frame in
            bridge.receive(SurfaceFrame.failure(id: frame.id!, error: "unknown surface method: x").asObject())
        }

        await #expect(throws: SurfaceError.remote("unknown surface method: x")) {
            try await bridge.openWorkspace(path: "/tmp")
        }
    }

    @Test("reload 会丢掉飞行中的请求，但继续等下一次 ready")
    func pageResetFailsInflight() async throws {
        let page = ScriptedPage()
        let bridge = SurfaceBridge()
        bridge.attach(page)
        bridge.receive(SurfaceFrame.event(method: "ready").asObject())

        let task = Task { try await bridge.openWorkspace(path: "/tmp") }
        for _ in 0..<40 where page.scripts.isEmpty {
            await Task.yield()
        }
        #expect(!page.scripts.isEmpty)

        bridge.notePageReset()
        await #expect(throws: SurfaceError.pageReset) {
            try await task.value
        }
        #expect(!bridge.isReady)

        // A later ready still lets the next call through.
        bridge.receive(SurfaceFrame.event(method: "ready").asObject())
        #expect(bridge.isReady)
    }

    @Test("openSession / startSession 带上对的方法和载荷")
    func sessionCommands() async throws {
        let page = ScriptedPage()
        let bridge = SurfaceBridge()
        bridge.attach(page)
        bridge.receive(SurfaceFrame.event(method: "ready").asObject())

        page.onEvaluate = { frame in
            bridge.receive(SurfaceFrame.response(id: frame.id!, value: .object([:])).asObject())
        }

        try await bridge.openSession(sessionId: "s-9")
        try await bridge.startSession(workspaceId: "ws-1")
        try await bridge.startSession()
        try await bridge.openSettings()
        try await bridge.archiveSession(sessionId: "s-9")
        try await bridge.renameSession(sessionId: "s-9", title: "你好")
        try await bridge.forkSession(sessionId: "s-9")

        let frames = try page.scripts.map { try ScriptedPage.frame(in: $0) }
        #expect(frames.map(\.method) == [
            "openSession", "startSession", "startSession", "openSettings",
            "archiveSession", "renameSession", "forkSession",
        ])
        #expect(frames[0].payload?["sessionId"]?.stringValue == "s-9")
        #expect(frames[1].payload?["workspaceId"]?.stringValue == "ws-1")
        #expect(frames[2].payload == .object([:]))
        #expect(frames[4].payload?["sessionId"]?.stringValue == "s-9")
        #expect(frames[5].payload?["sessionId"]?.stringValue == "s-9")
        #expect(frames[5].payload?["title"]?.stringValue == "你好")
        #expect(frames[6].payload?["sessionId"]?.stringValue == "s-9")
    }

    @Test("detach 丢掉飞行中的请求")
    func detachFailsInflight() async throws {
        let page = ScriptedPage()
        let bridge = SurfaceBridge()
        bridge.attach(page)
        bridge.receive(SurfaceFrame.event(method: "ready").asObject())

        let task = Task { try await bridge.openSession(sessionId: "s-1") }
        for _ in 0..<40 where page.scripts.isEmpty {
            await Task.yield()
        }
        #expect(!page.scripts.isEmpty)

        bridge.detach()
        await #expect(throws: SurfaceError.detached) {
            try await task.value
        }
        #expect(!bridge.isReady)
    }

    @Test("坏掉的 catalog 事件被丢掉，不回调")
    func malformedCatalogIsIgnored() {
        let bridge = SurfaceBridge()
        var seen: SurfaceCatalog?
        bridge.onCatalog = { seen = $0 }
        bridge.receive(
            SurfaceFrame.event(
                method: "catalog",
                payload: .object(["workspaces": .string("nope")])
            ).asObject()
        )
        #expect(seen == nil)
    }

    @Test("catalog 事件解出分组后的会话列表")
    func catalogEvent() {
        let bridge = SurfaceBridge()
        var seen: SurfaceCatalog?
        bridge.onCatalog = { seen = $0 }
        bridge.receive(
            SurfaceFrame.event(
                method: "catalog",
                payload: .object([
                    "currentSessionId": .string("s1"),
                    "workspaces": .array([
                        .object([
                            "workspaceId": .string("ws"),
                            "title": .string("proj"),
                            "path": .string("/tmp/proj"),
                            "sessions": .array([
                                .object([
                                    "sessionId": .string("s1"),
                                    "title": .string("你好"),
                                    "blank": .bool(false),
                                    "running": .bool(true),
                                    "updatedAt": .number(9),
                                ]),
                            ]),
                        ]),
                    ]),
                    "ungrouped": .array([]),
                ])
            ).asObject()
        )
        #expect(seen?.currentSessionId == "s1")
        #expect(seen?.workspaces.first?.title == "proj")
        #expect(seen?.workspaces.first?.sessions.first?.running == true)
    }

    @Test("selection 事件回调带上会话标题")
    func selectionEvent() {
        let bridge = SurfaceBridge()
        var seen: SurfaceSelection?
        bridge.onSelection = { seen = $0 }
        bridge.receive(
            SurfaceFrame.event(
                method: "selection",
                payload: .object([
                    "sessionId": .string("s9"),
                    "path": .string("/tmp/proj"),
                    "title": .string("proj"),
                ])
            ).asObject()
        )
        #expect(seen == SurfaceSelection(sessionId: "s9", path: "/tmp/proj", title: "proj"))
    }

    @Test("未知版本的帧被丢掉，不冒充 ready")
    func unknownVersionIsIgnored() {
        let bridge = SurfaceBridge()
        var frame = SurfaceFrame.event(method: "ready")
        frame.v = 2
        bridge.receive(frame.asObject())
        #expect(!bridge.isReady)
    }

    @Test("ready 超时")
    func readyTimeout() async {
        let bridge = SurfaceBridge()
        bridge.readyTimeout = .milliseconds(20)
        bridge.attach(ScriptedPage())
        await #expect(throws: SurfaceError.notReady) {
            try await bridge.openWorkspace(path: "/tmp")
        }
    }
}

extension SurfaceFrame {
    /// What `WKScriptMessage.body` looks like when the page posts an object.
    func asObject() -> Any {
        let data = try! JSONEncoder().encode(self)
        return try! JSONSerialization.jsonObject(with: data)
    }
}
