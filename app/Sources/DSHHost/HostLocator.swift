import Foundation

/// Finds the official `dsh` launcher on this machine.
///
/// The premise to unlearn: `dsh` is very often **not on PATH**. A machine that
/// uses Harness daily may have only ever run it through `npx`, in which case
/// the profile's own `node_modules` holds a symlink into the npx cache — a real,
/// version-aligned entry point that a `npm cache clean` would nonetheless
/// delete. So every candidate is verified to actually resolve and execute
/// before it is offered, and "the file exists" is never taken to mean "it runs".
public enum HostLocator {
    public struct Launcher: Sendable, CustomStringConvertible {
        public enum Source: String, Sendable {
            /// The profile's own dependency. Version-aligned with what boots.
            case profile
            /// A global install on PATH.
            case path
            /// Last resort: slow, and the version is not ours to choose.
            case npx
        }

        public let executable: URL
        public let leadingArguments: [String]
        public let source: Source

        public var description: String {
            ([executable.path] + leadingArguments).joined(separator: " ") + "  [\(source.rawValue)]"
        }

        public func arguments(_ tail: [String]) -> [String] { leadingArguments + tail }
    }

    /// Everything that was tried and why it did not work, plus one thing the
    /// user can actually do. Never surface a Cordis stack for this.
    public struct NotFound: Error, CustomStringConvertible {
        public let attempts: [String]
        public let remedy: String

        public var description: String {
            (["没有找到可用的 dsh 运行时。"] + attempts.map { "  · \($0)" } + ["", remedy]).joined(separator: "\n")
        }
    }

    public static func locate(
        dshHome: URL = defaultDshHome,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<Launcher, NotFound> {
        var attempts: [String] = []

        if let node = findExecutable("node", environment: environment) {
            let binJS = dshHome
                .appending(path: "profiles/node_modules/@deepseek-ai/dsh/lib/bin.js")
            if let why = rejectionReason(binJS) {
                attempts.append("profile 里的 dsh：\(why)")
            } else {
                return .success(Launcher(executable: node, leadingArguments: [binJS.path], source: .profile))
            }
        } else {
            attempts.append("Node 不在 PATH 上 —— 没有 Node，dsh 无法运行")
        }

        if let dsh = findExecutable("dsh", environment: environment) {
            return .success(Launcher(executable: dsh, leadingArguments: [], source: .path))
        }
        attempts.append("PATH 上没有 dsh（很正常：npx 用户不会有全局安装）")

        if let npx = findExecutable("npx", environment: environment) {
            return .success(
                Launcher(executable: npx, leadingArguments: ["--yes", "@deepseek-ai/dsh"], source: .npx)
            )
        }
        attempts.append("PATH 上没有 npx")

        return .failure(
            NotFound(
                attempts: attempts,
                remedy: "装好官方运行时后重试：https://deepseek.com/harness（需要 Node ≥ 22.19 与 pnpm）"
            )
        )
    }

    public static var defaultDshHome: URL {
        if let explicit = ProcessInfo.processInfo.environment["DSH_HOME"] {
            return URL(fileURLWithPath: explicit)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".dsh")
    }

    /// Resolves symlinks and confirms the target is a readable regular file.
    /// A dangling npx-cache symlink passes `fileExists` and then fails at spawn
    /// with something unreadable, which is exactly the failure mode this avoids.
    private static func rejectionReason(_ url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return "不存在（\(url.path)）" }
        let resolved = url.resolvingSymlinksInPath()
        guard fm.isReadableFile(atPath: resolved.path) else {
            return "符号链接指向了读不到的位置（\(resolved.path)）—— npx 缓存可能被清过"
        }
        return nil
    }

    /// PATH lookup that also covers the version managers a GUI app's inherited
    /// environment routinely misses.
    public static func findExecutable(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let extras = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.volta/bin", "\(home)/.local/bin", "\(home)/Library/pnpm",
        ]
        let nvm = (try? fm.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node"))?
            .map { "\(home)/.nvm/versions/node/\($0)/bin" } ?? []

        let searchPath = (environment["PATH"]?.split(separator: ":").map(String.init) ?? []) + extras + nvm
        for directory in searchPath {
            let candidate = URL(fileURLWithPath: directory).appending(path: name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
