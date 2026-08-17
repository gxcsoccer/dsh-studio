import SwiftUI
import DSHKit
import DSHClient
import DSHSurface

/// **W1 的原生侧栏** —— 替换官方 `sidebar.workspaces`。
///
/// 这个视图是整套架构的分界线（reference/native-slot-proxy.md §4 末尾）：
///
/// - 领域数据（工作区、会话、running 状态、标题投影）从 `DSHClient` 拿 ——
///   loopback 数据通道，**不经 WebView**（ADR-0002）。
/// - 编排状态（collapsed / selected）从 `instance.props` 拿 —— 控制通道。
/// - 领域动作（新建会话、归档、重命名）→ `client.rpc(...)`。
/// - 必须由 Web 侧 `ctx` 完成的回调（官方注入面）→ `instance.invoke(...)`。
///
/// 键盘可达 + VoiceOver 标签完整是本视图的验收门（migration-playbook.md §③）：
/// 原生化的意义就在这里，做丢了就白换。
public struct WorkspacesRailView: View {
    /// 编排：collapsed / selected / width。
    private let instance: SlotInstance

    @Environment(DSHClient.self) private var client
    @State private var localSelection: String?
    @State private var searchText = ""
    @State private var actionFailure: String?
    @FocusState private var listFocused: Bool

    public init(instance: SlotInstance) {
        self.instance = instance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let banner = client.link.bannerText {
                disconnectionBanner(banner)
            }
            if instance.props.collapsed {
                collapsedRail
            } else {
                sessionTree
            }
            if let actionFailure {
                Text(actionFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .accessibilityLabel("上一次操作失败：\(actionFailure)")
            }
        }
        .frame(minWidth: 220, idealWidth: instance.props.width ?? 260)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作区与会话")
        .onChange(of: instance.props.selected) { _, _ in
            // Web 侧确认了选中态 → 放弃本地乐观值。
            localSelection = nil
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            Text(instance.props.label ?? "工作区")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                newSession()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(instance.props.disabled)
            .help("新建会话（⌘N）")
            .accessibilityLabel("新建会话")
            .accessibilityHint(
                instance.can("startSession")
                    ? "调用官方侧栏的新建会话动作"
                    : "通过数据通道创建一个新会话"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func disconnectionBanner(_ text: String) -> some View {
        // 断连横幅：设计里点名要原生化的第一个东西（bridge-contract.md §2.3）。
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle")
            Text(text).font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("运行时连接状态")
        .accessibilityValue(text)
    }

    private var collapsedRail: some View {
        VStack(spacing: 10) {
            ForEach(client.workspaces) { workspace in
                Button {
                    select(workspace.workspaceId.rawValue)
                } label: {
                    Text(String(workspace.title.prefix(1)).uppercased())
                        .font(.caption.bold())
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("工作区 \(workspace.title)")
                .accessibilityHint("展开侧栏以查看会话")
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .accessibilityLabel("折叠的工作区导轨")
    }

    // MARK: 会话树

    private var sessionTree: some View {
        VStack(spacing: 0) {
            TextField("搜索会话", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .accessibilityLabel("搜索会话")

            List(selection: selectionBinding) {
                ForEach(client.workspaces) { workspace in
                    Section {
                        let sessions = filtered(client.visibleSessions(in: workspace))
                        if sessions.isEmpty {
                            Text("暂无会话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(workspace.title) 暂无会话")
                        } else {
                            ForEach(sessions) { session in
                                row(session)
                                    .tag(session.sessionId.rawValue)
                            }
                        }
                    } header: {
                        Text(workspace.title)
                            .accessibilityLabel("工作区 \(workspace.title)")
                            .accessibilityValue(workspace.path)
                    }
                }

                let loose = filtered(client.looseSessions())
                if !loose.isEmpty {
                    Section("其他会话") {
                        ForEach(loose) { session in
                            row(session).tag(session.sessionId.rawValue)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .focused($listFocused)
            .accessibilityLabel("会话树")
            .accessibilityHint("使用上下方向键在会话间移动，回车打开")
        }
    }

    private func row(_ session: SessionSummary) -> some View {
        HStack(spacing: 6) {
            // 品牌色只出现在「模型正在动」的地方（继承 playground 的视觉结论）。
            Circle()
                .fill(session.running ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .lineLimit(1)
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("归档会话") { archive(session.sessionId) }
            Button("重命名为「\(session.displayTitle)」…") { rename(session.sessionId) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("会话 \(session.displayTitle)")
        .accessibilityValue(session.running ? "模型正在运行" : "空闲")
        .accessibilityHint("回车打开该会话，右键可归档")
        .accessibilityAddTraits(isSelected(session) ? [.isButton, .isSelected] : .isButton)
    }

    private func isSelected(_ session: SessionSummary) -> Bool {
        (localSelection ?? instance.props.selected) == session.sessionId.rawValue
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { localSelection ?? instance.props.selected },
            set: { newValue in
                localSelection = newValue
                if let newValue { select(newValue) }
            }
        )
    }

    private func filtered(_ sessions: [SessionSummary]) -> [SessionSummary] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: 动作

    /// 选中一个会话。
    ///
    /// ⚠️ 与文档不符之处：reference/native-slot-proxy.md §4 写的是
    /// `client.rpc(.sessionOpen(id))`，但上游 `RpcMethodMap` 里**没有**
    /// `session.open` —— 「当前打开哪个会话」是壳的导航状态，不是 runtime
    /// 的领域事实。所以这里走注入面（`selectSession`），没有该动作时退化为
    /// 纯本地选中态。详见交付报告。
    private func select(_ sessionID: String) {
        guard instance.can("selectSession") else { return }
        instance.invokeDetached("selectSession", [.string(sessionID)])
    }

    /// 新建会话。
    ///
    /// 优先走 Web 注入面（官方 `startSession` 会顺带处理导航与目录流程）；
    /// 没有该动作时用数据通道的 `session.create` 兜底。
    private func newSession() {
        if instance.can("startSession") {
            instance.invokeDetached("startSession")
            return
        }
        Task { @MainActor in
            do {
                _ = try await client.createSession(in: client.workspaces.first?.workspaceId)
                actionFailure = nil
            } catch {
                actionFailure = "新建会话失败：\(error)"
            }
        }
    }

    private func archive(_ sessionID: SessionID) {
        Task { @MainActor in
            do {
                try await client.archiveSession(sessionID)
                actionFailure = nil
            } catch {
                actionFailure = "归档失败：\(error)"
            }
        }
    }

    private func rename(_ sessionID: SessionID) {
        Task { @MainActor in
            do {
                // W1 先用一个确定性的默认名；输入框留给 W2 的表单原生化。
                try await client.renameSession(sessionID, title: "未命名会话")
                actionFailure = nil
            } catch {
                actionFailure = "重命名失败：\(error)"
            }
        }
    }
}
