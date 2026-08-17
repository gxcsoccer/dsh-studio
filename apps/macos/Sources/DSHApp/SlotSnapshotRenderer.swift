import SwiftUI
import AppKit
import Foundation
import DSHKit
import DSHClient
import DSHSurface

/// 原生插槽视图的**离屏渲染**入口（`dsh-studio --render-slot-snapshots <dir>`）。
///
/// 为什么需要它：这台机器上拿不到运行时截图（屏幕录制权限被拒），而视觉这一半的
/// 验收标准是「看不出接缝」—— 没有图就只能靠嘴说「我抄了 CSS」。这条命令把视觉
/// 自检变成可复现的产物，PNG 可以直接和官方 UI 的截图并排看。
///
/// ## 为什么不是 `ImageRenderer`
///
/// 第一版用的是 `ImageRenderer`，四张图渲出来**只有 section header**：行全没了。
/// 实测（一个 `VStack { Text("PLAIN"); ScrollView { Text("IN-SCROLL") } }` 的探针）
/// 结论是 —— `ImageRenderer` 画得出 `PLAIN`，画不出 `IN-SCROLL`：它不走 AppKit
/// 的窗口/布局流程，`NSScrollView` 这类需要真实布局 pass 的宿主视图在里面是空的。
/// 那种图比没有图更糟：它会让「列表没渲染」看起来像「列表就是空的」。
///
/// 所以改成**真实的离屏窗口**：`NSWindow`（屏幕外、never ordered front）+
/// `NSHostingView`，转几拍 run loop 让 SwiftUI 完成布局与数据落地，再用
/// `cacheDisplay(in:to:)` 把视图层次自己画进 bitmap。这条路不碰屏幕录制权限
/// （我们画的是自己的视图，不是屏幕），拿到的却是**真实布局后的**像素：
/// ScrollView、hover 态、动态色都按真身解析。
///
/// 它**不是**测试替身：渲染的是生产视图本身（`WorkspacesRailView`），props 走
/// 真实的 `SlotInstance`，领域数据走真实的 `DSHClient`（喂给它一个假 transport，
/// 而不是给视图开后门）。唯一被钉死的是「现在」—— 否则相对时间每次都不一样，
/// PNG 就没法比对。
///
/// 尺寸也不是随手挑的，两张都是官方**让给这一格**的宽度，不是整条侧栏的宽度：
///
/// - 展开态 244：侧栏列 260 − `.root { padding: 6px 12px }` 的左 12 + `.regionArea`
///   的 `margin-left: -4px` → 从列左边 8 起，一直到列右边（`margin-right` 把右侧
///   12 的内缩抵掉了），即 260 − 8 ≈ 252 的盒子里，行的可用宽 244。
/// - 折叠态 36：`.root.collapsed { padding: 18px 10px 6px }` 且
///   `.collapsed .regionArea { margin: 0; padding-left: 0 }` —— 56 的导轨减掉两侧
///   10，region 只有 **36** 宽，正好等于一个 36×36 控件。第一版按 56 画，于是
///   两个圆钮在图里居中，而真机上它们是撑满 36 的。
@MainActor
enum SlotSnapshotRenderer {
    static let flag = "--render-slot-snapshots"

    /// 展开态画布：宽度 = 官方侧栏让给这一格的宽度。
    static let expandedSize = CGSize(width: 244, height: 520)
    /// 折叠态画布：`.collapsed .regionArea` 的实际宽度（56 − 10 × 2）。
    static let collapsedSize = CGSize(width: 36, height: 520)

    /// 若命令行要求渲染，就渲染并返回 true（调用方随后退出进程）。
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        let directory = arguments.count > index + 1
            ? URL(fileURLWithPath: arguments[index + 1])
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do {
            let written = try render(into: directory)
            for url in written { print("wrote \(url.path)") }
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
        return true
    }

    /// 渲染四张图：展开/折叠 × 浅色/深色。
    static func render(into directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 离屏窗口也需要一个 NSApplication；`.prohibited` 让它不进 Dock、不抢焦点。
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let client = try fixtureClient()
        // 记账一行：一张空图有两种成因（数据没到 / 视图没画），把它们分开。
        print("fixture: \(client.workspaces.count) workspace(s), \(client.sessionsByID.count) session(s)")

        let schemes: [(String, NSAppearance?)] = [
            ("light", NSAppearance(named: .aqua)),
            ("dark", NSAppearance(named: .darkAqua)),
        ]
        var written: [URL] = []
        for (name, appearance) in schemes {
            for (suffix, collapsed, size) in [
                ("expanded", false, expandedSize),
                ("collapsed", true, collapsedSize),
            ] {
                written.append(try capture(
                    view: rail(collapsed: collapsed, client: client),
                    size: size,
                    appearance: appearance,
                    to: directory.appendingPathComponent("w1-sidebar-\(suffix)-\(name).png")
                ))
            }
        }
        return written
    }

    // MARK: 视图

    private static func rail(collapsed: Bool, client: DSHClient) -> some View {
        // `wide` 是上游的折叠事实（true = 展开），不是我们自己的 `collapsed`。
        let instance = SlotInstance.preview(
            slot: W1.workspacesSlot,
            props: [
                "wide": .bool(!collapsed),
                "label": .string("工作区"),
                "selected": .string("s-2"),
            ],
            actions: ["startSession", "selectSession", "expandSidebar"]
        )
        return WorkspacesRailView(instance: instance, now: fixtureNow)
            .environment(client)
    }

    // MARK: 捕获

    /// 在一个屏幕外的窗口里真实布局，然后把视图层次画进 PNG。
    private static func capture(
        view: some View,
        size: CGSize,
        appearance: NSAppearance?,
        to url: URL
    ) throws -> URL {
        let window = NSWindow(
            // 放到屏幕外：这条命令可能在开发者正在用的桌面上跑，不该闪一下窗口。
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        // 必须真的 order in：`NSScrollView` 只有进了窗口层次才会布局它的
        // documentView —— 这正是 `ImageRenderer` 那一版整列空白的原因。
        // `orderBack` + 屏幕外坐标 = 不可见但活着。
        window.orderBack(nil)

        // 转几拍 run loop：SwiftUI 的布局、`onAppear`、以及 `@Observable` 的
        // 首次读取都发生在这里。0.1s 的余量对 4 张图的总耗时无感。
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.renderFailed(url.lastPathComponent)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(url.lastPathComponent)
        }
        try png.write(to: url)
        window.orderOut(nil)
        return url
    }

    // MARK: 假数据（走真实的数据通道解码路径）

    /// 钉死的「现在」：2026-09-01 12:00:00Z。相对时间因此是确定的。
    static let fixtureNow = Date(timeIntervalSince1970: 1_788_264_000)

    /// 一次快照拉取的完成信号。
    ///
    /// 全程在 MainActor 上：我们**故意**不把渲染搬到后台 —— `NSHostingView` 与
    /// SwiftUI 都要主线程，而这条命令没有 run loop 在跑，所以自己转一小段。
    @MainActor
    private final class SnapshotWait {
        var finished = false
        var failure: (any Error)?
    }

    private static func fixtureClient() throws -> DSHClient {
        let client = DSHClient(provider: FixtureProvider())
        let wait = SnapshotWait()
        Task { @MainActor in
            do { try await client.refreshSnapshot() } catch { wait.failure = error }
            wait.finished = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !wait.finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let failure = wait.failure { throw failure }
        return client
    }

    enum SnapshotError: Error, CustomStringConvertible {
        case renderFailed(String)

        var description: String {
            switch self {
            case .renderFailed(let name): "离屏窗口没能产出 \(name)"
            }
        }
    }
}

/// 假 transport：只回答 `workspace.list` / `session.list`，SSE 直接结束。
private struct FixtureProvider: DSHConnectionProvider {
    func connect() throws -> DSHConnectionHandle {
        DSHConnectionHandle(
            descriptor: BridgeDescriptor(token: "snapshot"),
            transport: FixtureTransport()
        )
    }
}

private struct FixtureTransport: DSHTransport {
    func post(path: String, body: Data, headers: [String: String]) async throws -> HTTPReply {
        let method = (try? JSONValue.decode(body))?["method"]?.stringValue ?? ""
        let value: String = switch method {
        case "workspace.list": FixtureTransport.workspaces
        case "session.list": FixtureTransport.sessions
        default: "{}"
        }
        return HTTPReply(status: 200, body: Data(#"{"ok":true,"value":\#(value)}"#.utf8))
    }

    func openStream(
        path: String,
        headers: [String: String]
    ) async throws -> (status: Int, chunks: AsyncThrowingStream<Data, any Error>) {
        (200, AsyncThrowingStream { $0.finish() })
    }

    /// 一个工作区 + 一组未分组会话：足够让四种行状态（running、选中、普通、
    /// 长标题截断）同时出现在一张图里。
    static let workspaces = """
    {"items":[
      {"workspaceId":"w-1","path":"/Users/me/projj/dsh-studio","title":"dsh-studio",
       "sessionIds":["s-1","s-2","s-3","s-4"],"createdAt":"","updatedAt":""}
    ],"archivedSessionIds":[]}
    """

    static let sessions = """
    {"items":[
      {"sessionId":"s-1","updatedAt":1788263940000,"running":true,"blank":false,
       "projections":{"asOfSeq":9,"values":{"title":"修 W1 的几何与视觉"}}},
      {"sessionId":"s-2","updatedAt":1788260400000,"running":false,"blank":false,
       "projections":{"asOfSeq":4,"values":{"title":"原生插槽层的落位协议"}}},
      {"sessionId":"s-3","updatedAt":1788177600000,"running":false,"blank":false,
       "projections":{"asOfSeq":2,"values":{"title":"一个特别长的会话标题，用来验证省略号是否落在右侧时间之前"}}},
      {"sessionId":"s-4","updatedAt":1785585600000,"running":false,"blank":false,
       "cwd":"/Users/me/projj/deepseek-harness"},
      {"sessionId":"s-5","updatedAt":1788263400000,"running":false,"blank":false,
       "projections":{"asOfSeq":1,"values":{"title":"没有工作区的会话"}}}
    ]}
    """
}
