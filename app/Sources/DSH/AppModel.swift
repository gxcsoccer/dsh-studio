import AppKit
import Foundation
import SwiftUI

enum RuntimePhase: Equatable {
    case idle
    case checking
    case missingPrereqs
    case installingProfile
    case starting
    case waitingHealth
    case ready
    case stopping
    case failed
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: RuntimePhase = .idle
    @Published var statusText: String = ""
    @Published var logLines: [String] = []
    @Published var webURL: URL = URL(string: "http://127.0.0.1:3080")!
    @Published var bridgeHealthy = false
    @Published var webHealthy = false
    @Published var nodeVersion: String?
    @Published var hasDSH = false
    @Published var lastError: String?
    @Published var notifyEnabled = true
    @Published var composerDraft = ""
    @Published var lastComposerSent: String?

    let workspace = WorkspaceStore()
    let supervisor = RuntimeSupervisor()
    let notifications = NotificationBridge()
    let theme = ThemeStore()

    init() {
        supervisor.onLog = { [weak self] line in
            Task { @MainActor in
                self?.appendLog(line)
            }
        }
        supervisor.onPhase = { [weak self] phase, text in
            Task { @MainActor in
                self?.phase = phase
                self?.statusText = text
            }
        }
        supervisor.onURLs = { [weak self] web, bridgeOK, webOK in
            Task { @MainActor in
                if let web { self?.webURL = web }
                self?.bridgeHealthy = bridgeOK
                self?.webHealthy = webOK
            }
        }
        supervisor.onError = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
                self?.phase = .failed
            }
        }
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
    }

    func bootstrap() async {
        phase = .checking
        statusText = L10n.t("正在检查本机环境…", "Checking local environment…")
        let path = PathResolver.augmentedPATH()
        nodeVersion = PathResolver.nodeVersion(path: path)
        hasDSH = PathResolver.locate("dsh", path: path) != nil
            || PathResolver.locate("npx", path: path) != nil
        let nodeOK = PathResolver.nodeMeetsMinimum(nodeVersion)
        if !nodeOK || !hasDSH {
            phase = .missingPrereqs
            statusText = L10n.t("需要先安装 Node 与 dsh", "Node and dsh are required")
            return
        }
        await startRuntime()
    }

    func startRuntime() async {
        lastError = nil
        await supervisor.start(workspace: workspace.url)
        notifications.start(enabled: notifyEnabled)
        await theme.pushToBridge()
    }

    func restartRuntime() async {
        notifications.stop()
        await supervisor.stop()
        await startRuntime()
    }

    func repairProfile() async {
        phase = .installingProfile
        statusText = L10n.t("正在安装 / 修复 studio profile…", "Installing / repairing the studio profile…")
        do {
            try await supervisor.installOrRepairProfile()
            await startRuntime()
        } catch {
            lastError = error.localizedDescription
            phase = .failed
        }
    }

    func quitRuntime() async {
        notifications.stop()
        await supervisor.stop()
        phase = .idle
    }

    func submitComposer() {
        let text = composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastComposerSent = text
        composerDraft = ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

