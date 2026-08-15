import AppKit
import DSHSurface
import SwiftUI

/// Session jump + a few chrome actions. Title matches come from the catalog;
/// snippets come from `session.search` on the gateway. An empty query is
/// actions plus a short recents list — the sidebar already has the full roster.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { model.closePalette() }

            VStack(spacing: 0) {
                TextField("搜索会话或正文", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(14)
                    .focused($fieldFocused)
                    .onChange(of: query) { _, value in
                        selectedIndex = 0
                        Task { await model.searchPalette(value) }
                    }
                    .onSubmit(activate)
                    .onKeyPress { handle($0) }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                rowButton(row, index: index)
                                    .id(row.id)
                                if showsRecentsDivider(after: index) {
                                    Divider().padding(.vertical, 4)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard rows.indices.contains(index) else { return }
                        proxy.scrollTo(rows[index].id, anchor: .center)
                    }
                }
            }
            .frame(width: 480, height: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 24)
        }
        .onAppear { fieldFocused = true }
        .onExitCommand { model.closePalette() }
        .onChange(of: rows.count) { _, _ in
            if selectedIndex >= rows.count {
                selectedIndex = max(rows.count - 1, 0)
            }
        }
    }

    private var rows: [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            var list: [Row] = [
                .action("new", "新会话", "plus"),
                .action("open", "打开工作区…", "folder"),
                .action("settings", "设置…", "gearshape"),
            ]
            if let current = model.currentSession, !current.blank {
                list.append(.action("rename", "重命名当前会话…", "pencil"))
                list.append(.action("fork", "分叉当前会话", "arrow.triangle.branch"))
                list.append(.action("archive", "归档当前会话", "archivebox"))
            }
            list.append(contentsOf: model.catalog.recents().map(Row.hit))
            return list
        }
        return model.catalog.hits(matching: needle, content: model.contentSnippets).map(Row.hit)
    }

    private func showsRecentsDivider(after index: Int) -> Bool {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let actions = rows.prefix { if case .action = $0 { true } else { false } }.count
        return index == actions - 1 && rows.count > actions
    }

    private func rowButton(_ row: Row, index: Int) -> some View {
        Button {
            selectedIndex = index
            activate()
        } label: {
            Group {
                switch row {
                case .action(_, let title, let systemImage):
                    Label(title, systemImage: systemImage)
                case .hit(let hit):
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.session.title).lineLimit(1)
                        Text(hit.workspace)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let snippet = hit.snippet, !snippet.isEmpty {
                            Text(snippet)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                index == selectedIndex ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { inside in
            if inside { selectedIndex = index }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if isComposing { return .ignored }
        switch press.key {
        case .downArrow:
            move(1)
            return .handled
        case .upArrow:
            move(-1)
            return .handled
        case .return:
            activate()
            return .handled
        default:
            return .ignored
        }
    }

    private var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
    }

    private func activate() {
        guard rows.indices.contains(selectedIndex) else { return }
        switch rows[selectedIndex] {
        case .action("new", _, _):
            run { await model.startSession() }
        case .action("open", _, _):
            openWorkspace()
        case .action("settings", _, _):
            run { await model.openSettings() }
        case .action("rename", _, _):
            model.closePalette()
            model.promptRename()
        case .action("fork", _, _):
            if let id = model.catalog.currentSessionId {
                run { await model.forkSession(id) }
            }
        case .action("archive", _, _):
            if let id = model.catalog.currentSessionId {
                run { await model.archiveSession(id) }
            }
        case .hit(let hit):
            run { await model.openSession(hit.session.sessionId) }
        case .action:
            break
        }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        model.closePalette()
        Task { await work() }
    }

    private func openWorkspace() {
        model.closePalette()
        if let url = model.workspaces.chooseDirectory() {
            Task { await model.open(workspace: url) }
        }
    }

    private enum Row: Identifiable {
        case action(String, String, String)
        case hit(SurfaceCatalogHit)

        var id: String {
            switch self {
            case .action(let id, _, _): return "action:\(id)"
            case .hit(let hit): return "hit:\(hit.id)"
            }
        }
    }
}
