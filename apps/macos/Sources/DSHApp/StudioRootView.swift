import SwiftUI
import DSHKit
import DSHClient
import DSHSurface

/// 窗口骨架：左边原生插槽出口，右边官方 Web UI。
///
/// 这就是混合期的样子（ARCHITECTURE.md §4.1 的那张图）。每完成一波迁移，
/// 左边变宽一点，右边变窄一点，直到 W7 右边不再渲染任何 UI。
public struct StudioRootView: View {
    private let environment: StudioEnvironment

    public init(environment: StudioEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        HSplitView {
            NativeSlotOutlet(
                slot: W1.workspacesSlot,
                coordinator: environment.coordinator,
                stage: environment.host.stage
            ) {
                placeholder
            }
            .frame(minWidth: 0, idealWidth: 260)

            WebContainer(bridge: environment.webBridge, url: environment.shellURL)
                .frame(minWidth: 480)
        }
        .environment(environment.client)
        .toolbar {
            ToolbarItem(placement: .status) {
                phaseBadge
            }
        }
    }

    /// 握手完成前 / 降级后的占位。
    ///
    /// 降级时这里是**空的**：整条侧栏交还给官方 Web UI 渲染（ADR-0004），
    /// 我们不画一个「加载失败」的假侧栏去和它抢位置。
    @ViewBuilder
    private var placeholder: some View {
        switch environment.coordinator.phase {
        case .launching, .configuring:
            VStack(spacing: 8) {
                ProgressView()
                Text("正在等待官方 UI 的插槽表…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("正在与官方 UI 握手")
        case .live:
            // 已握手但这一格没有实例：官方仍在渲染，原生侧不占位。
            EmptyView()
        case .degradedWebOnly:
            EmptyView()
        }
    }

    private var phaseBadge: some View {
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
}

@main
public struct DSHStudioApp: App {
    @State private var environment = StudioEnvironment()

    public init() {}

    public var body: some Scene {
        WindowGroup("DSH Studio") {
            StudioRootView(environment: environment)
                .task { environment.launch() }
        }
        .commands {
            CommandMenu("Studio") {
                // 对照热键 ⌥⇧D：把当前插槽在 native / web 间热切
                // （surface-manifest.md §5：开发期对照 + 线上用户自救通道）。
                Button("对照：原生 / 官方切换") {
                    environment.toggleCompare()
                }
                .keyboardShortcut("d", modifiers: [.option, .shift])

                Button("重新同步会话快照") {
                    Task { @MainActor in try? await environment.client.refreshSnapshot() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
