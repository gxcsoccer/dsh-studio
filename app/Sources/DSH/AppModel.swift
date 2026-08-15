import AppKit
import DSHHost
import DSHKit
import DSHSurface
import Foundation
import Observation

/// What the window is showing, and why.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case checking
        case blocked(Preflight)
        case needsWorkspace
        case launching(String)
        case ready(URL)
        case failed(summary: String, detail: String)
    }

    /// Pinned in the studio bundle patch. The bind address is a decision, so it
    /// is a constant on both sides rather than something either side discovers.
    static let surfacePort: UInt16 = 3099
    static let surfaceURL = URL(string: "http://127.0.0.1:\(surfacePort)")!

    private(set) var phase: Phase = .checking
    let workspaces = WorkspaceStore()
    let notifier = TurnNotifier()
    let surface = SurfaceBridge()
    private(set) var surfaceSelection: SurfaceSelection?
    private(set) var catalog = SurfaceCatalog.empty
    /// Last chrome action that failed. Shown in the sidebar so a dead ⌘N is
    /// a sentence, not a shrug.
    private(set) var chromeNote: String?
    var paletteOpen = false
    /// Content hits from `session.search`. Title matches stay on the catalog.
    private(set) var contentSnippets: [SurfaceSearchSnippet] = []
    private var searchGeneration = 0

    private var host: HostProcess?
    /// False when we attached to a runtime somebody else started; quitting must
    /// not take down a host this app does not own.
    private var ownsHost = false
    private var keyMonitor: Any?

    var workspaceName: String {
        surfaceSelection?.title
            ?? workspaces.current?.lastPathComponent
            ?? "未选择工作区"
    }

    /// Window chrome title. WKWebView will try to use `document.title`
    /// (often the workspace name); chrome wins.
    var windowTitle: String {
        SurfaceChromeTitle.resolve(catalog: catalog, selection: surfaceSelection)
    }

    var currentSession: SurfaceSessionRow? {
        guard let id = catalog.currentSessionId else { return nil }
        return catalog.lookup(id)?.session
    }

    private func pushWindowTitle() {
        StudioChrome.apply(windowTitle)
    }

    init() {
        surface.onSelection = { [weak self] selection in
            let previous = self?.surfaceSelection?.sessionId
            self?.surfaceSelection = selection
            if previous != selection.sessionId {
                ChromeLog.line("selection id=\(selection.sessionId ?? "nil") title=\(selection.title ?? "nil")")
            }
            self?.pushWindowTitle()
        }
        surface.onCatalog = { [weak self] catalog in
            let previous = self?.catalog.currentSessionId
            self?.catalog = catalog
            if previous != catalog.currentSessionId {
                ChromeLog.line("catalog current=\(catalog.currentSessionId ?? "nil") groups=\(catalog.workspaces.count)")
            }
            self?.pushWindowTitle()
        }
        installChromeKeys()
    }

    func boot() async {
        installChromeKeys()
        phase = .checking

        let preflight = Preflight.run()
        guard preflight.passed else {
            phase = .blocked(preflight)
            return
        }
        guard let workspace = Self.requestedWorkspace() ?? workspaces.current else {
            phase = .needsWorkspace
            return
        }
        workspaces.remember(workspace)
        await start(anchoredAt: workspace)
        await register(workspace)
        if case .ready = phase {
            await select(workspace)
        }
    }

    /// `open -a DSH.app --args --workspace <dir>`, and by extension opening a
    /// folder with Studio from Finder. Opening a project straight into the app
    /// is how anyone actually starts work; making them re-pick a directory they
    /// just chose is the kind of friction that keeps a tool out of the loop.
    private static func requestedWorkspace() -> URL? {
        let arguments = CommandLine.arguments
        guard
            let flag = arguments.firstIndex(of: "--workspace"),
            arguments.index(after: flag) < arguments.endIndex
        else { return nil }

        let url = URL(fileURLWithPath: arguments[arguments.index(after: flag)])
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return url
    }

    /// Opening a workspace registers it with the running runtime. It does *not*
    /// restart anything.
    ///
    /// One runtime already serves many workspaces — the registry is a
    /// process-wide table and every session carries its own immutable cwd, so
    /// the host's working directory is only a fallback for calls that have no
    /// session. Tearing the process down to "switch" would kill every live
    /// agent to change a default, which is a data-loss bug wearing the costume
    /// of a workspace switcher.
    func open(workspace: URL) async {
        workspaces.remember(workspace)
        if case .ready = phase {
            await register(workspace)
            await select(workspace)
        } else {
            await start(anchoredAt: workspace)
            await register(workspace)
            if case .ready = phase {
                await select(workspace)
            }
        }
    }

    /// The explicit, destructive one — bound to a shortcut the user has to
    /// choose deliberately.
    func restart() async {
        let anchor = workspaces.current
        await stopHost()
        guard let anchor else { return await boot() }
        await start(anchoredAt: anchor)
    }

    private func register(_ workspace: URL) async {
        let client = ApiClient(baseURL: Self.surfaceURL)
        // Idempotent by contract: an already-registered path comes back with
        // `created: false`, so reopening a familiar project is a no-op rather
        // than an error to explain.
        _ = try? await client.call(WorkspaceCreateRequest(path: workspace.path))
    }

    /// Ask the page-side plugin to land on this workspace. Registration is
    /// host state and already done; selection is client-side, which is why
    /// this goes over the chrome channel and not the gateway.
    ///
    /// Failure is swallowed: the workspace is registered either way, and a
    /// picker success must not become a failed launch just because the page
    /// has not attached yet.
    private func select(_ workspace: URL) async {
        _ = try? await surface.openWorkspace(path: workspace.path)
    }

    func openSession(_ sessionId: String) async {
        _ = try? await surface.openSession(sessionId: sessionId)
    }

    /// Open the workspace's draft session. Reuse lives on the page — unused
    /// blanks are hidden from the catalog the moment they are not current,
    /// so minting here would only pile up invisible rows.
    func startSession(workspaceId: String? = nil) async {
        chromeNote = "正在开新会话…"
        do {
            try await surface.startSession(workspaceId: workspaceId ?? catalog.inferredWorkspaceId)
            chromeNote = nil
        } catch {
            chromeNote = error.localizedDescription
        }
    }

    func archiveSession(_ sessionId: String) async {
        chromeNote = nil
        ChromeLog.line("archive \(sessionId)")
        do {
            try await surface.archiveSession(sessionId: sessionId)
            ChromeLog.line("archive ok \(sessionId)")
        } catch {
            ChromeLog.line("archive fail \(error.localizedDescription)")
            chromeNote = error.localizedDescription
        }
    }

    func forkSession(_ sessionId: String) async {
        chromeNote = nil
        do {
            try await surface.forkSession(sessionId: sessionId)
        } catch {
            chromeNote = error.localizedDescription
        }
    }

    /// System sheet, not a SwiftUI overlay: the page already owns a modal
    /// stack, and a second one on top of WKWebView is how focus gets lost.
    func promptRename(sessionId: String? = nil) {
        let id = sessionId ?? catalog.currentSessionId
        guard let id, let found = catalog.lookup(id) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名会话"
        alert.informativeText = "新标题会固定下来，不再被自动改写。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: found.session.blank ? "" : found.session.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        let window = NSApp.keyWindow
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            Task { await self.renameSession(id, title: title) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    func renameSession(_ sessionId: String, title: String) async {
        chromeNote = nil
        do {
            try await surface.renameSession(sessionId: sessionId, title: title)
        } catch {
            chromeNote = error.localizedDescription
        }
    }

    func revealWorkspace(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openSettings() async {
        chromeNote = nil
        closePalette()
        do {
            try await surface.openSettings()
        } catch {
            chromeNote = error.localizedDescription
        }
    }

    func togglePalette() {
        if paletteOpen {
            closePalette()
        } else {
            paletteOpen = true
        }
    }

    func closePalette() {
        paletteOpen = false
        contentSnippets = []
        searchGeneration += 1
    }

    /// Debounced full-text search. Failure is silent: title hits still work,
    /// and the host may not have opened the search index yet.
    func searchPalette(_ query: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            contentSnippets = []
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard generation == searchGeneration else { return }
        do {
            let value = try await ApiClient(baseURL: Self.surfaceURL)
                .call(SessionSearchRequest(query: needle))
            guard generation == searchGeneration else { return }
            contentSnippets = value.items.map {
                SurfaceSearchSnippet(sessionId: $0.sessionId, snippet: $0.snippet)
            }
        } catch {
            if generation == searchGeneration { contentSnippets = [] }
        }
    }

    func shutdown() async {
        notifier.stop()
        await stopHost()
    }

    /// ⌘N must not depend on the web view yielding the event. A local monitor
    /// sees the key before WKWebView's "new window" equivalent can swallow it.
    private func installChromeKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let key = Self.chromeKey(event) else { return event }
            Task { @MainActor in
                switch key {
                case .newSession: await self?.startSession()
                case .palette: self?.togglePalette()
                case .settings: await self?.openSettings()
                }
            }
            return nil
        }
    }

    /// Character string is unreliable under an IME; keyCodes are ANSI.
    private static func chromeKey(_ event: NSEvent) -> ChromeKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control)
        else { return nil }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if chars == "n" || event.keyCode == 45 { return .newSession }
        if chars == "k" || event.keyCode == 40 { return .palette }
        if chars == "," || event.keyCode == 43 { return .settings }
        return nil
    }

    private enum ChromeKey {
        case newSession, palette, settings
    }

    // MARK: - Runtime

    /// - Parameter anchor: the child's working directory. Only a fallback for
    ///   sessions and sandbox calls that carry no cwd of their own, so it is
    ///   fixed for the life of the process rather than following the UI.
    private func start(anchoredAt anchor: URL) async {
        // Adopt a runtime that is already answering rather than colliding with
        // it. Reopening the app after a crash, or running it beside a terminal
        // `dsh`, should not become a port fight.
        if await surfaceIsAnswering() {
            ownsHost = false
            phase = .launching("接管已在运行的运行时…")
            await becomeReady()
            return
        }

        guard case .success(let launcher) = HostLocator.locate() else {
            phase = .blocked(Preflight.run())
            return
        }

        phase = .launching("正在启动 DeepSeek Harness…")
        let process = HostProcess(
            launcher: launcher,
            profile: "studio",
            port: Self.surfacePort,
            workingDirectory: anchor
        )
        host = process
        ownsHost = true

        do {
            try await process.start()
            await becomeReady()
        } catch {
            let output = await process.output()
            phase = .failed(
                summary: (error as? HostProcess.Failure)?.summary ?? String(describing: error),
                detail: output.isEmpty ? "运行时没有输出任何内容。" : String(output.suffix(4000))
            )
        }
    }

    private func becomeReady() async {
        notifier.start(baseURL: Self.surfaceURL)
        phase = .ready(Self.surfaceURL)
    }

    private func stopHost() async {
        notifier.stop()
        if ownsHost, let host { await host.stop() }
        host = nil
        ownsHost = false
    }

    private func surfaceIsAnswering() async -> Bool {
        (try? await ApiClient(baseURL: Self.surfaceURL).call(HostDescribeRequest())) != nil
    }
}
