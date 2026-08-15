import DSHHost
import Foundation

/// What the machine needs before a session can happen, reported in product
/// language.
///
/// The rule this exists to enforce: a failed check hands back **an action**, not
/// a diagnosis the user has to translate. Nobody opening a desktop app should
/// meet a Cordis stack trace, and "Node not found" is not an action either.
struct Preflight: Sendable {
    struct Check: Sendable, Identifiable {
        enum State: Sendable { case ok(String), missing(action: String, url: URL?) }
        let id: String
        let title: String
        let state: State

        var isOK: Bool { if case .ok = state { return true } else { return false } }
    }

    let checks: [Check]
    var passed: Bool { checks.allSatisfy(\.isOK) }

    static let harnessInstall = URL(string: "https://deepseek.com/harness")!

    static func run(profile: String = "studio") -> Preflight {
        var checks: [Check] = []

        // Node. Everything else is downstream of it, so its absence is reported
        // first and the rest are still reported — a list of one problem at a
        // time is a worse first run than a list of three.
        let node = HostLocator.findExecutable("node")
        let nodeState: Check.State =
            if let node { .ok(version(of: node) ?? node.path) }
            else { .missing(action: "安装 Node 22.19 或更新版本", url: URL(string: "https://nodejs.org")) }
        checks.append(Check(id: "node", title: "Node 运行时", state: nodeState))

        // pnpm. Easy to miss, because it is only needed the moment a plugin is
        // installed into a profile — which is exactly first run.
        let pnpmState: Check.State =
            HostLocator.findExecutable("pnpm") != nil
            ? .ok("已就绪")
            : .missing(action: "安装 pnpm", url: URL(string: "https://pnpm.io/installation"))
        checks.append(Check(id: "pnpm", title: "pnpm（安装插件时需要）", state: pnpmState))

        switch HostLocator.locate() {
        case .success(let launcher):
            checks.append(Check(id: "dsh", title: "DeepSeek Harness 运行时", state: .ok(launcher.source.rawValue)))
        case .failure:
            checks.append(
                Check(
                    id: "dsh",
                    title: "DeepSeek Harness 运行时",
                    state: .missing(action: "安装官方运行时", url: harnessInstall)
                )
            )
        }

        let profileDir = HostLocator.defaultDshHome.appending(path: "profiles/\(profile)")
        let composed = (try? Data(contentsOf: profileDir.appending(path: "package.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let bundles = ((composed?["dsh"] as? [String: Any])?["profile"] as? [String: Any])?["bundles"] as? [String]
        let profileState: Check.State =
            if let bundles, bundles.contains("dsh-studio") { .ok(bundles.joined(separator: " → ")) }
            else { .missing(action: "建立 studio 组合（tools/provision-profile）", url: nil) }
        checks.append(Check(id: "profile", title: "studio 工作组合", state: profileState))

        return Preflight(checks: checks)
    }

    private static func version(of executable: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
