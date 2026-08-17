import SwiftUI
import DSHKit
import DSHClient
import DSHSurface

/// 窗口骨架：**官方 Web UI 占满内容区，原生插槽视图盖在它让出的那一格里**。
///
/// 这里曾经是 `HSplitView { nativeRail; webPane }` —— 原生侧栏作为 WebView 的
/// 兄弟列，把官方 UI 整体右推一列。那是错的：`sidebar.workspaces` 只是官方
/// 侧栏**内部**的一格，官方的 logo、新会话、设置仍然由 Web 渲染，硬开一列的
/// 结果就是同一条侧栏被劈成两半（见 W1 交付报告的截图）。
///
/// 现在只有一个内容区：WebView。原生插槽层是它的 `overlay`，两者 frame 恒等，
/// 落位靠 `slot/rect` 上报的几何（`NativeSlotLayer`）。W7 之后 WebView 不再
/// 渲染任何 UI，那时这个 `overlay` 关系原地反转成「只剩原生」，不需要重写布局。
public struct StudioRootView: View {
    private let environment: StudioEnvironment

    public init(environment: StudioEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        VStack(spacing: 0) {
            StudioStatusBar(
                linkBanner: environment.client.link.bannerText,
                controlNotice: environment.coordinator.controlLinkHealth.noticeText
            )
            webPane
                .overlay(alignment: .topLeading) { nativeSlots }
        }
        .environment(environment.client)
        .toolbar {
            ToolbarItem(placement: .status) { phaseBadge }
        }
    }

    /// 原生插槽层：与 WebView 同尺寸、同原点，按 Web 让出的 rect 落位。
    private var nativeSlots: some View {
        NativeSlotLayer(
            slot: W1.workspacesSlot,
            coordinator: environment.coordinator,
            stage: environment.host.stage
        )
    }

    /// 右半屏：有壳地址就渲染官方 UI，没有就显示失联态（不是白屏）。
    @ViewBuilder
    private var webPane: some View {
        if let url = environment.shellURL {
            WebContainer(bridge: environment.webBridge, url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RuntimeOfflineView(detail: environment.shellFailure) {
                environment.retryShellDiscovery()
            }
        }
    }

    /// 插槽状态胶囊 —— **只在 DEBUG 构建里出现**。
    ///
    /// 截图里标题栏正中那颗灰色的「原生侧栏已接管」是开发期记账：它回答的是
    /// 「握手成功了吗、这一格挂上了吗」，对用户没有意义。发布构建里让它继续占
    /// 着官方标题栏的中缝，就是把脚手架当成了产品的一部分。失联/降级这类**用户
    /// 需要知道**的状态不在这里 —— 它们在 `StudioStatusBar` 的横幅上，那条横幅
    /// 任何构建都会显示（bridge-contract.md §2.3）。
    @ViewBuilder
    private var phaseBadge: some View {
        #if DEBUG
        debugPhaseBadge
        #else
        EmptyView()
        #endif
    }

    #if DEBUG
    private var debugPhaseBadge: some View {
        let text: String = switch environment.coordinator.phase {
        case .launching: "等待 surface/ready"
        case .configuring: "下发 manifest"
        case .live: environment.host.stage.visibleInstance(of: W1.workspacesSlot) == nil
            ? "原生侧栏待挂载"
            : "原生侧栏已接管"
        case .degradedWebOnly(let reason): "已降级为官方 Web UI（\(reason)）"
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("插槽状态：\(text)")
    }
    #endif
}

@main
public struct DSHStudioApp: App {
    @State private var environment = StudioEnvironment()

    public init() {
        // `--render-slot-snapshots <dir>`：离屏渲染原生插槽视图并退出。
        //
        // 视觉自检需要图，而这台机器上拿不到运行时截图（屏幕录制权限被拒）。
        // 挂在 App 的 init 上而不是另开一个 target：渲染的必须是**生产视图
        // 本身**，另开 target 就要么复制视图代码，要么把它降级成库 —— 前者会
        // 立刻和真身漂移，后者为了截图去改架构分层。
        if SlotSnapshotRenderer.runIfRequested() { exit(0) }
    }

    public var body: some Scene {
        WindowGroup("DSH Studio") {
            StudioRootView(environment: environment)
                .frame(minWidth: 860, minHeight: 560)
                .task { environment.launch() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandMenu("Studio") {
                // 对照热键 ⌥⇧D：把当前插槽在 native / web 间热切
                // （surface-manifest.md §5：开发期对照 + 线上用户自救通道）。
                Button("对照：原生 / 官方切换") {
                    environment.toggleCompare()
                }
                .keyboardShortcut("d", modifiers: [.option, .shift])

                Button("重新查找 runtime") {
                    environment.retryShellDiscovery()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("重新同步会话快照") {
                    Task { @MainActor in try? await environment.client.refreshSnapshot() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
