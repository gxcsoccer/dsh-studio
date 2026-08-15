import Foundation

enum SupervisorError: LocalizedError {
    case missingLauncher
    case profileInstallFailed(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingLauncher:
            return L10n.t("找不到 dsh 或 npx", "Could not find dsh or npx")
        case .profileInstallFailed(let s):
            return s
        case .startFailed(let s):
            return s
        }
    }
}

final class RuntimeSupervisor: @unchecked Sendable {
    var onLog: ((String) -> Void)?
    var onPhase: ((RuntimePhase, String) -> Void)?
    var onURLs: ((URL?, Bool, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private var process: Process?
    private var webURL = URL(string: "http://127.0.0.1:3080")!
    private let bridgeHealth = URL(string: "http://127.0.0.1:43180/health")!
    private var workspace: URL = FileManager.default.homeDirectoryForCurrentUser
    private let profileName = "studio"

    func start(workspace: URL) async {
        self.workspace = workspace
        await stop()
        onPhase?(.starting, L10n.t("正在启动 dsh --profile studio", "Starting dsh --profile studio"))
        do {
            try await ensureProfile()
            try launch()
            onPhase?(.waitingHealth, L10n.t("等待 Web 与桥接就绪", "Waiting for Web and bridge"))
            await waitUntilHealthy()
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func stop() async {
        guard let process else { return }
        onPhase?(.stopping, L10n.t("正在停止运行时", "Stopping runtime"))
        terminate(process)
        self.process = nil
    }

    func installOrRepairProfile() async throws {
        try await ensureProfile(force: true)
    }

    var supportPluginDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DSHStudio/plugin", isDirectory: true)
    }

    var dshHome: URL {
        if let raw = ProcessInfo.processInfo.environment["DSH_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
    }

    var profileDir: URL {
        dshHome.appendingPathComponent("profiles/\(profileName)", isDirectory: true)
    }

    func locatePluginSource() -> URL? {
        let fm = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("plugin", isDirectory: true)
        if let bundled, fm.fileExists(atPath: bundled.appendingPathComponent("package.json").path) {
            return bundled
        }
        if fm.fileExists(atPath: supportPluginDir.appendingPathComponent("package.json").path) {
            return supportPluginDir
        }
        let exe = URL(fileURLWithPath: Bundle.main.bundlePath)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            exe.appendingPathComponent("../plugin"),
            exe.appendingPathComponent("../../plugin"),
            exe.appendingPathComponent("../../../plugin"),
            exe.appendingPathComponent("../../../../plugin"),
            cwd.appendingPathComponent("plugin"),
            cwd.appendingPathComponent("../plugin"),
        ]
        for url in candidates {
            let resolved = url.standardizedFileURL
            if fm.fileExists(atPath: resolved.appendingPathComponent("package.json").path) {
                return resolved
            }
        }
        return nil
    }

    func copyPluginIntoSupport() throws -> URL {
        let dest = supportPluginDir
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest.appendingPathComponent("themes"), withIntermediateDirectories: true)
        guard let source = locatePluginSource() else {
            if fm.fileExists(atPath: dest.appendingPathComponent("package.json").path) {
                return dest
            }
            throw SupervisorError.profileInstallFailed(
                L10n.t("找不到 dsh-studio 插件目录", "dsh-studio plugin directory not found")
            )
        }
        if source.standardizedFileURL == dest.standardizedFileURL {
            return dest
        }
        for name in ["package.json", "index.js", "cordis.patch.yml"] {
            let from = source.appendingPathComponent(name)
            let to = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) {
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            }
        }
        let themeFrom = source.appendingPathComponent("themes")
        let themeTo = dest.appendingPathComponent("themes")
        if fm.fileExists(atPath: themeFrom.path) {
            if let files = try? fm.contentsOfDirectory(at: themeFrom, includingPropertiesForKeys: nil) {
                for file in files {
                    let to = themeTo.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: to.path) { try? fm.removeItem(at: to) }
                    try? fm.copyItem(at: file, to: to)
                }
            }
        }
        return dest
    }

    func profileLooksReady() -> Bool {
        let pkg = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkg),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("dsh-web-app") && text.contains("dsh-studio")
    }

    func ensureProfile(force: Bool = false) async throws {
        if !force && profileLooksReady() { return }
        onPhase?(.installingProfile, L10n.t("正在写入 studio profile", "Writing studio profile"))
        let plugin = try copyPluginIntoSupport()
        let path = PathResolver.augmentedPATH()
        guard let dsh = PathResolver.locate("dsh", path: path) ?? PathResolver.locate("npx", path: path) else {
            throw SupervisorError.missingLauncher
        }
        let useNpx = dsh.lastPathComponent == "npx"
        func argv(_ rest: [String]) -> [String] {
            if useNpx { return ["--yes", "@deepseek-ai/dsh"] + rest }
            return rest
        }
        try runTool(dsh, argv(["plugin", "--profile", profileName, "add", "@deepseek-ai/dsh-web-app"]))
        try runTool(dsh, argv(["plugin", "--profile", profileName, "add", plugin.path]))
    }

    private func launch() throws {
        let path = PathResolver.augmentedPATH()
        guard let launcher = PathResolver.locate("dsh", path: path) ?? PathResolver.locate("npx", path: path) else {
            throw SupervisorError.missingLauncher
        }
        let proc = Process()
        proc.executableURL = launcher
        if launcher.lastPathComponent == "npx" {
            proc.arguments = ["--yes", "@deepseek-ai/dsh", "--profile", profileName]
        } else {
            proc.arguments = ["--profile", profileName]
        }
        proc.currentDirectoryURL = workspace
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        if let key = KeychainStore.loadAPIKey() {
            env["DEEPSEEK_API_KEY"] = key
        }
        proc.environment = env

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        attach(out, prefix: "")
        attach(err, prefix: "")
        proc.terminationHandler = { [weak self] finished in
            guard let self else { return }
            if finished.terminationStatus != 0 {
                self.onLog?(
                    L10n.t(
                        "运行时退出，状态 \(finished.terminationStatus)",
                        "Runtime exited with status \(finished.terminationStatus)"
                    )
                )
            }
        }
        do {
            try proc.run()
        } catch {
            throw SupervisorError.startFailed(error.localizedDescription)
        }
        process = proc
    }

    private func attach(_ pipe: Pipe, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.split(whereSeparator: \.isNewline) {
                let text = prefix + String(line)
                self?.onLog?(text)
                self?.ingestWebURL(from: text)
            }
        }
    }

    private func ingestWebURL(from line: String) {
        let pattern = #"https?://(?:127\.0\.0\.1|localhost):\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range, in: line),
              let url = URL(string: String(line[swiftRange])) else { return }
        if url.port == 3080 || line.lowercased().contains("web") {
            webURL = url
        }
    }

    private func waitUntilHealthy() async {
        let deadline = Date().addingTimeInterval(60)
        var bridgeOK = false
        var webOK = false
        while Date() < deadline {
            if process?.isRunning == false {
                onError?(L10n.t("运行时在就绪前退出", "Runtime exited before becoming ready"))
                return
            }
            bridgeOK = await ping(bridgeHealth, accept: [200])
            let pair = await pingWeb(webURL)
            webOK = pair.ok
            if let preferred = pair.url { webURL = preferred }
            onURLs?(webURL, bridgeOK, webOK)
            if bridgeOK && webOK {
                onPhase?(.ready, L10n.t("已就绪", "Ready"))
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        if bridgeOK {
            onPhase?(.ready, L10n.t("桥已就绪，Web 仍在等待", "Bridge ready, still waiting for Web"))
            onURLs?(webURL, true, webOK)
            return
        }
        onError?(L10n.t("等待运行时超时", "Timed out waiting for the runtime"))
    }

    private struct WebPing {
        var ok: Bool
        var url: URL?
    }

    private func pingWeb(_ url: URL) async -> WebPing {
        if await ping(url, accept: [200, 204, 301, 302, 304]) {
            return WebPing(ok: true, url: url)
        }
        let fallback = Self.swapLoopback(url)
        if await ping(fallback, accept: [200, 204, 301, 302, 304]) {
            return WebPing(ok: true, url: fallback)
        }
        // 403 on 127.0.0.1 is the documented trusted-host fence — try localhost.
        if await statusCode(url) == 403 {
            if await ping(fallback, accept: [200, 204, 301, 302, 304, 403]) {
                let ok = await statusCode(fallback) != 403
                return WebPing(ok: ok || await statusCode(fallback) == 200, url: fallback)
            }
            return WebPing(ok: false, url: fallback)
        }
        return WebPing(ok: false, url: nil)
    }

    private func ping(_ url: URL, accept: Set<Int>) async -> Bool {
        if let code = await statusCode(url) {
            return accept.contains(code)
        }
        return false
    }

    private func statusCode(_ url: URL) async -> Int? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    static func swapLoopback(_ url: URL) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if comps?.host == "127.0.0.1" {
            comps?.host = "localhost"
        } else if comps?.host == "localhost" {
            comps?.host = "127.0.0.1"
        }
        return comps?.url ?? url
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.interrupt()
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.standardOutput = nil
        process.standardError = nil
    }

    private func runTool(_ url: URL, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = PathResolver.augmentedPATH()
        if let key = KeychainStore.loadAPIKey() {
            env["DEEPSEEK_API_KEY"] = key
        }
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw SupervisorError.profileInstallFailed(error.localizedDescription)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            onLog?(text)
        }
        if proc.terminationStatus != 0 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SupervisorError.profileInstallFailed(
                text.isEmpty
                    ? L10n.t("profile 安装失败", "Profile install failed")
                    : text
            )
        }
    }
}
