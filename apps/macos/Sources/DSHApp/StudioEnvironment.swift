import SwiftUI
import DSHKit
import DSHClient
import DSHSurface

/// 应用级接线 —— **唯一同时认识两条通道的地方**。
///
/// `DSHClient`（领域）与 `DSHSurface`（编排）在这里被放到一起，但它们彼此
/// 不认识：视图从前者拿数据，从后者拿编排状态。W8 拆 WebView 时，这个文件
/// 里删掉 surface 那几行即可（ADR-0002）。
@MainActor
@Observable
public final class StudioEnvironment {
    public let client: DSHClient
    public let channel: ControlChannel
    public let host: NativeSlotHost
    public let coordinator: SurfaceCoordinator
    public let webBridge: WebViewControlBridge

    /// 官方 UI 壳的地址（来自 `bridge.json`，缺省时留空并显示提示）。
    public private(set) var shellURL: URL?
    /// 启动自检失败（例如 manifest 说要原生但没有实现）。
    public private(set) var startupFailure: String?

    public init(manifest: SurfaceManifest = .w1Default) {
        client = DSHClient()
        channel = ControlChannel()
        host = NativeSlotHost()
        coordinator = SurfaceCoordinator(channel: channel, host: host, manifest: manifest)
        webBridge = WebViewControlBridge(channel: channel)

        // W1：`sidebar.workspaces` 的原生实现。
        //
        // 工厂只拿到编排 props；领域数据由视图自己从 DSHClient 取（environment）。
        host.register(W1.workspacesSlot) { instance in
            AnyView(WorkspacesRailView(instance: instance))
        }
    }

    public func launch() {
        shellURL = (try? BridgeDescriptorLoader().load())?.shellURL
        do {
            try coordinator.start()
        } catch {
            startupFailure = String(describing: error)
        }
        // 数据通道独立启动：WebView 起不来也不影响会话列表（ADR-0002 的收益）。
        client.start()
    }

    /// `⌥⇧D`：把 W1 插槽在 native / web 间热切（不重启、不刷新）。
    public func toggleCompare() {
        Task { @MainActor in
            _ = await coordinator.toggleMode(for: W1.workspacesSlot)
        }
    }
}
