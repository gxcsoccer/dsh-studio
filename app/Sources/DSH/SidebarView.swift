import AppKit
import DSHSurface
import SwiftUI

/// Native session list. The rows are a projection the page already computed;
/// clicking one asks the page to navigate. That split is the whole point of
/// the chrome channel: chrome lives here, selection lives there.
///
/// Session row chrome copies the official workspace list, not a pile of
/// footer buttons: a draft has no menu; a real row shows relative time, and
/// hover (or an open menu) swaps that time for ⋮. The three actions are the
/// official ones — 重命名 / 分叉会话 / 归档会话.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            ForEach(model.catalog.workspaces) { workspace in
                Section(workspace.title) {
                    if workspace.sessions.isEmpty {
                        Text("还没有对话")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(workspace.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.sessionId)
                    }
                }
            }

            if !model.catalog.ungrouped.isEmpty {
                Section("未分组") {
                    ForEach(model.catalog.ungrouped) { session in
                        SessionRow(session: session)
                            .tag(session.sessionId)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first ?? model.catalog.currentSessionId,
               model.catalog.lookup(id)?.session.blank != true
            {
                sessionActions(id)
            }
        }
        .onDeleteCommand {
            if let session = model.currentSession, !session.blank {
                Task { await model.archiveSession(session.sessionId) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await model.startSession() }
                } label: {
                    Label("新会话", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityHint("在当前工作区开一个空白会话")

                if let note = model.chromeNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.togglePalette()
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .help("搜索 ⌘K")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.startSession() }
                } label: {
                    Label("新会话", systemImage: "square.and.pencil")
                }
                .help("新会话 ⌘N")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                Task { await model.openSettings() }
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func sessionActions(_ id: String) -> some View {
        Button("重命名") { model.promptRename(sessionId: id) }
        Button("分叉会话") { Task { await model.forkSession(id) } }
        Button("归档会话") { Task { await model.archiveSession(id) } }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.catalog.currentSessionId },
            set: { id in
                guard let id else { return }
                Task { await model.openSession(id) }
            }
        )
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: SurfaceSessionRow
    @State private var hovering = false
    @State private var menuOpen = false

    var body: some View {
        HStack(spacing: 6) {
            Text(session.blank ? "新会话" : session.title)
                .lineLimit(1)
            Spacer(minLength: 0)
            if session.running {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("正在运行")
            }
            if !session.blank {
                trailing
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background { RowHover { hovering = $0 } }
        .accessibilityElement(children: .combine)
        .accessibilityHint(session.blank ? "" : "悬停后可打开会话操作")
        .contextMenu {
            if !session.blank { sessionActions }
        }
    }

    /// Official CSS: time is the idle occupant of this slot; hover / an open
    /// menu hide the time and show ⋮ in the same place, so the title does not jump.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                Text(SurfaceRelativeTime.label(updatedAt: session.updatedAt, now: timeline.date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(showMenu ? 0 : 1)
            }
            SessionMoreButton(
                title: session.title,
                onRename: { model.promptRename(sessionId: session.sessionId) },
                onFork: { Task { await model.forkSession(session.sessionId) } },
                onArchive: { Task { await model.archiveSession(session.sessionId) } },
                onMenuOpen: { menuOpen = $0 }
            )
            .opacity(showMenu ? 1 : 0)
            .allowsHitTesting(showMenu)
        }
        .frame(width: 36, alignment: .trailing)
        .layoutPriority(1)
    }

    private var showMenu: Bool { hovering || menuOpen }

    @ViewBuilder
    private var sessionActions: some View {
        Button("重命名") { model.promptRename(sessionId: session.sessionId) }
        Button("分叉会话") { Task { await model.forkSession(session.sessionId) } }
        Button("归档会话") { Task { await model.archiveSession(session.sessionId) } }
    }

}

/// AppKit ⋮ — a SwiftUI `Button`/`Menu` inside a selecting `List` is treated
/// as a row click and the action never runs.
private struct SessionMoreButton: NSViewRepresentable {
    var title: String
    var onRename: () -> Void
    var onFork: () -> Void
    var onArchive: () -> Void
    var onMenuOpen: (Bool) -> Void

    func makeNSView(context: Context) -> MoreDotsButton {
        let button = MoreDotsButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.title = "⋮"
        button.font = .systemFont(ofSize: 15, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.show(_:))
        button.toolTip = "会话操作"
        return button
    }

    func updateNSView(_ button: MoreDotsButton, context: Context) {
        context.coordinator.onRename = onRename
        context.coordinator.onFork = onFork
        context.coordinator.onArchive = onArchive
        context.coordinator.onMenuOpen = onMenuOpen
        button.setAccessibilityLabel("会话“\(title)”的操作")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onRename: () -> Void = {}
        var onFork: () -> Void = {}
        var onArchive: () -> Void = {}
        var onMenuOpen: (Bool) -> Void = { _ in }

        @objc func show(_ sender: NSButton) {
            let menu = NSMenu()
            menu.addItem(item("重命名", "pencil", #selector(rename)))
            menu.addItem(item("分叉会话", "arrow.triangle.branch", #selector(fork)))
            menu.addItem(item("归档会话", "archivebox", #selector(archive)))
            onMenuOpen(true)
            let height = MainActor.assumeIsolated { sender.bounds.height }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: height + 2), in: sender)
            onMenuOpen(false)
        }

        private func item(_ title: String, _ symbol: String, _ selector: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            return item
        }

        @objc func rename() { onRename() }
        @objc func fork() { onFork() }
        @objc func archive() { onArchive() }
    }
}

private final class MoreDotsButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 24) }
}

/// SwiftUI `onHover` does not fire on sidebar `List` rows. A tracking area does.
private struct RowHover: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverProbe {
        let view = HoverProbe()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: HoverProbe, context: Context) {
        view.onHover = onHover
    }
}

private final class HoverProbe: NSView {
    var onHover: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
