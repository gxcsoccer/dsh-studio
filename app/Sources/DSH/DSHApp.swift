import AppKit
import SwiftUI

@main
struct DSHApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.theme)
                .environmentObject(model.workspace)
                .studioSurface(model.theme.tokens, density: model.theme.density, typeScale: model.theme.typeScale)
                .frame(minWidth: 960, minHeight: 620)
                .task { await model.bootstrap() }
                .onDisappear {
                    Task { await model.quitRuntime() }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("打开工作区…", "Open Workspace…")) {
                    model.workspace.pickFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandMenu("Studio") {
                Button(L10n.t("重启运行时", "Restart Runtime")) {
                    Task { await model.restartRuntime() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(L10n.t("修复 Profile", "Repair Profile")) {
                    Task { await model.repairProfile() }
                }
                Divider()
                Button(L10n.t("命令面板", "Command Palette")) {
                    model.theme.commandPaletteOpen = true
                }
                .keyboardShortcut("k", modifiers: [.command])
                Button(L10n.t("测试通知", "Test Notification")) {
                    Task { await model.notifications.sendTest() }
                }
            }
            CommandMenu(L10n.t("显示", "View")) {
                Toggle(L10n.t("侧栏", "Sidebar"), isOn: $model.theme.showSidebar)
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Toggle(L10n.t("检查器", "Inspector"), isOn: $model.theme.showInspector)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Toggle(L10n.t("输入栏", "Composer"), isOn: $model.theme.showComposer)
                Toggle(L10n.t("会话顶栏", "Session header"), isOn: $model.theme.showHeader)
                Toggle(L10n.t("状态栏", "Status bar"), isOn: $model.theme.showStatus)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.theme)
                .studioSurface(model.theme.tokens, density: model.theme.density, typeScale: model.theme.typeScale)
                .frame(minWidth: 460, minHeight: 360)
        }

        MenuBarExtra("DSH Studio", systemImage: "circle.grid.cross") {
            Text(model.statusText.isEmpty ? L10n.t("未启动", "Idle") : model.statusText)
            Divider()
            Button(L10n.t("显示窗口", "Show Window")) {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(L10n.t("重启运行时", "Restart Runtime")) {
                Task { await model.restartRuntime() }
            }
            Button(L10n.t("修复 Profile", "Repair Profile")) {
                Task { await model.repairProfile() }
            }
            Divider()
            Button(L10n.t("退出", "Quit")) {
                Task {
                    await model.quitRuntime()
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
