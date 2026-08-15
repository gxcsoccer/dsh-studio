import SwiftUI

struct CommandItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var action: () -> Void
}

struct CommandPalette: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.tokens) private var tokens
    @Environment(\.density) private var density
    @Environment(\.typeScale) private var typeScale
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TokenPaint.color(tokens.overlay)
                .ignoresSafeArea()
                .onTapGesture { theme.commandPaletteOpen = false }
            VStack(spacing: 0) {
                TextField(L10n.t("搜索命令…", "Search commands…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: tokens.typeSize("lg", scale: typeScale)))
                    .foregroundStyle(TokenPaint.color(tokens.text.primary))
                    .padding(tokens.space("4", density: density))
                    .focused($focused)
                    .onSubmit { runSelected() }
                    .accessibilityLabel(L10n.t("命令面板", "Command palette"))
                Hairline()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            Button {
                                item.action()
                                theme.commandPaletteOpen = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: tokens.typeSize("md", scale: typeScale), weight: .medium))
                                        .foregroundStyle(TokenPaint.color(tokens.text.primary))
                                    Text(item.subtitle)
                                        .font(.system(size: tokens.typeSize("xs", scale: typeScale)))
                                        .foregroundStyle(TokenPaint.color(tokens.text.secondary))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(tokens.space("3", density: density))
                                .background(index == selected ? TokenPaint.color(tokens.surface) : TokenPaint.color(tokens.elevated))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 520)
            .background(
                TokenPaint.color(tokens.elevated),
                in: RoundedRectangle(cornerRadius: tokens.radiusValue("lg"), style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.radiusValue("lg"), style: .continuous)
                    .stroke(TokenPaint.color(tokens.border.subtle), lineWidth: 1)
            )
        }
        .onAppear {
            focused = true
            selected = 0
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .onExitCommand { theme.commandPaletteOpen = false }
    }

    private var filtered: [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = all
        if q.isEmpty { return items }
        return items.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    private var all: [CommandItem] {
        [
            CommandItem(id: "open", title: L10n.t("打开工作区", "Open Workspace"), subtitle: "⌘O") {
                model.workspace.pickFolder()
            },
            CommandItem(id: "restart", title: L10n.t("重启运行时", "Restart Runtime"), subtitle: "⇧⌘R") {
                Task { await model.restartRuntime() }
            },
            CommandItem(id: "repair", title: L10n.t("修复 Profile", "Repair Profile"), subtitle: "studio") {
                Task { await model.repairProfile() }
            },
            CommandItem(id: "sidebar", title: L10n.t("切换侧栏", "Toggle sidebar"), subtitle: "⌥⌘S") {
                theme.showSidebar.toggle()
            },
            CommandItem(id: "inspector", title: L10n.t("切换检查器", "Toggle inspector"), subtitle: "⌥⌘I") {
                theme.showInspector.toggle()
            },
            CommandItem(id: "composer", title: L10n.t("切换输入栏", "Toggle composer"), subtitle: "") {
                theme.showComposer.toggle()
            },
            CommandItem(id: "notify", title: L10n.t("测试通知", "Test notification"), subtitle: "") {
                Task { await model.notifications.sendTest() }
            },
        ] + theme.packs.map { pack in
            CommandItem(id: "theme-\(pack.id)", title: L10n.t("主题：", "Theme: ") + pack.displayName, subtitle: pack.id) {
                theme.select(themeId: pack.id)
            }
        }
    }

    private func runSelected() {
        let items = filtered
        guard items.indices.contains(selected) else {
            theme.commandPaletteOpen = false
            return
        }
        items[selected].action()
        theme.commandPaletteOpen = false
    }
}
