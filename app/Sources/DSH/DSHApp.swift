import SwiftUI

@main
struct DSHApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("DSH Studio", id: "studio") {
            ContentView()
                .environment(model)
                .task { await model.boot() }
                .onDisappear { Task { await model.shutdown() } }
        }
        .windowToolbarStyle(.unified)
        .commands { StudioCommands(model: model) }
        .onChange(of: scenePhase) { _, phase in
            // Notifications for a window you are already looking at are noise,
            // and noise is what gets notifications switched off for good.
            model.notifier.isWindowFocused = phase == .active
        }
    }
}

struct StudioCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新会话") {
                Task { await model.startSession() }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("打开工作区…") {
                if let url = model.workspaces.chooseDirectory() {
                    Task { await model.open(workspace: url) }
                }
            }
            .keyboardShortcut("o")

            Menu("最近的工作区") {
                ForEach(model.workspaces.recents, id: \.self) { url in
                    Button(url.lastPathComponent) { Task { await model.open(workspace: url) } }
                }
            }
            .disabled(model.workspaces.recents.isEmpty)

            Divider()

            Button("重命名会话…") {
                model.promptRename()
            }
            .disabled(model.currentSession == nil || model.currentSession?.blank == true)

            Button("分叉会话") {
                if let id = model.currentSession?.sessionId {
                    Task { await model.forkSession(id) }
                }
            }
            .disabled(model.currentSession == nil || model.currentSession?.blank == true)

            Button("归档会话") {
                if let id = model.currentSession?.sessionId {
                    Task { await model.archiveSession(id) }
                }
            }
            .disabled(model.currentSession == nil || model.currentSession?.blank == true)
        }

        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                Task { await model.openSettings() }
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("搜索") {
                model.togglePalette()
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandMenu("运行时") {
            Button("重启运行时") { Task { await model.restart() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Text(model.workspaceName)
        }
    }
}
