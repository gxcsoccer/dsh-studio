import SwiftUI
import os
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
    /// 为什么还没有壳地址 —— 显示给用户看的人话（失联态必须可见）。
    public private(set) var shellFailure: String?
    /// 启动自检失败（例如 manifest 说要原生但没有实现）。
    public private(set) var startupFailure: String?

    /// dogfood 逃生阀：TS 侧的 `studio-surface` 还没写 `bridge.json` 时，
    /// 直接用环境变量指一个官方 `dsh web` 的地址，先把宿主跑起来。
    public static let shellURLOverrideKey = "DSH_STUDIO_SHELL_URL"

    private let environmentValues: [String: String]
    /// 启动路径要可诊断：dogfood 时「它到底连上了没有」必须能从日志回答，
    /// 不能只能从屏幕上猜。
    @ObservationIgnored private let logger = Logger(subsystem: "com.dsh.studio", category: "app")
    @ObservationIgnored private var discovery: Task<Void, Never>?
    /// 只在失联原因**变化**时记一次日志：3s 一轮的重试不该把 os_log 刷满。
    @ObservationIgnored private var loggedFailure: String?

    public init(
        manifest: SurfaceManifest = .w1Default,
        environmentValues: [String: String] = ProcessInfo.processInfo.environment,
        manifestSource: SurfaceCoordinator.ManifestSource? = nil
    ) {
        self.environmentValues = environmentValues
        client = DSHClient()
        channel = ControlChannel()
        host = NativeSlotHost()
        // G-4：manifest 的唯一真相源是 runtime 的 `/studio/surface`（= profile
        // 里那份 YAML）。传进来的 `manifest` 只是拿不到时的兜底。
        let source = manifestSource ?? { [runtime = RuntimeManifestSource()] in await runtime.load() }
        coordinator = SurfaceCoordinator(
            channel: channel,
            host: host,
            manifest: manifest,
            manifestSource: source
        )
        webBridge = WebViewControlBridge(channel: channel)

        // W1：`sidebar.workspaces` 的原生实现。
        //
        // 工厂只拿到编排 props；领域数据由视图自己从 DSHClient 取（environment）。
        host.register(W1.workspacesSlot) { instance in
            AnyView(WorkspacesRailView(instance: instance))
        }
    }

    deinit {
        discovery?.cancel()
    }

    public func launch() {
        resolveShellURL()
        do {
            try coordinator.start()
        } catch {
            startupFailure = String(describing: error)
        }
        // 数据通道独立启动：WebView 起不来也不影响会话列表（ADR-0002 的收益）。
        client.start()
        startShellDiscovery()
    }

    /// 读一次 `bridge.json`（或环境变量覆盖）拿官方壳地址。
    public func resolveShellURL() {
        if let override = environmentValues[StudioEnvironment.shellURLOverrideKey],
           let url = URL(string: override), url.scheme != nil {
            shellURL = url
            shellFailure = nil
            loggedFailure = nil
            logger.notice("shell url from \(StudioEnvironment.shellURLOverrideKey, privacy: .public): \(url.absoluteString, privacy: .public)")
            return
        }
        do {
            let descriptor = try BridgeDescriptorLoader().load()
            if let url = descriptor.shellURL {
                shellURL = url
                shellFailure = nil
                loggedFailure = nil
                logger.notice("shell url from bridge.json: \(url.absoluteString, privacy: .public)")
            } else {
                noteOffline("bridge.json 里没有 webUrl（studio-surface 尚未写入官方壳地址）")
            }
        } catch {
            noteOffline(String(describing: error))
        }
    }

    /// 「与 runtime 失联」要显示在屏幕上，也要留在日志里。
    private func noteOffline(_ detail: String) {
        shellFailure = detail
        guard loggedFailure != detail else { return }
        loggedFailure = detail
        logger.error("runtime offline: \(detail, privacy: .public)")
    }

    /// 后台每 3s 重试一次，直到拿到壳地址。
    ///
    /// 用户先开 app 再开 runtime 是最常见的顺序；那种情况下要求他重启 app
    /// 才能看到界面，就是把「失联」做成了「坏掉」。
    private func startShellDiscovery() {
        guard discovery == nil, shellURL == nil else { return }
        discovery = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                guard self.shellURL == nil else { return }
                self.resolveShellURL()
            }
        }
    }

    /// 「重新查找 runtime」按钮 / ⌘R。
    public func retryShellDiscovery() {
        resolveShellURL()
        startShellDiscovery()
    }

    /// `⌥⇧D`：把 W1 插槽在 native / web 间热切（不重启、不刷新）。
    public func toggleCompare() {
        Task { @MainActor in
            _ = await coordinator.toggleMode(for: W1.workspacesSlot)
        }
    }
}
