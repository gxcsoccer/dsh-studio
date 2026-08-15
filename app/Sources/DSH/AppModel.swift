import DSHHost
import DSHKit
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

    private var host: HostProcess?
    /// False when we attached to a runtime somebody else started; quitting must
    /// not take down a host this app does not own.
    private var ownsHost = false

    var workspaceName: String { workspaces.current?.lastPathComponent ?? "未选择工作区" }

    func boot() async {
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
        await start(in: workspace)
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

    func open(workspace: URL) async {
        workspaces.remember(workspace)
        await stopHost()
        await start(in: workspace)
    }

    func restart() async {
        guard let workspace = workspaces.current else { return await boot() }
        await stopHost()
        await start(in: workspace)
    }

    func shutdown() async {
        notifier.stop()
        await stopHost()
    }

    // MARK: - Runtime

    private func start(in workspace: URL) async {
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
            workingDirectory: workspace
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
