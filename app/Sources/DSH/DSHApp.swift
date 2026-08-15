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
            // "Add", not "open": this registers the directory and it appears in
            // the sidebar immediately, but selecting it is client-side state the
            // native side cannot reach yet. Calling it Open would promise
            // something that does not happen.
            Button("添加工作区…") {
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
        }

        CommandMenu("运行时") {
            Button("重启运行时") { Task { await model.restart() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Text(model.workspaceName)
        }
    }
}
