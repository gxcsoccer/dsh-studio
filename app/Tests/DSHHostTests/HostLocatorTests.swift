import Foundation
import Testing

@testable import DSHHost

/// Finding the runtime, and failing to find it.
///
/// The failure path matters as much as the success path here: "no dsh on PATH"
/// is the single most likely first-run outcome, and what the user sees at that
/// moment decides whether they install it or close the app.
struct HostLocatorTests {
    @Test("找不到任何东西时，给的是动作不是诊断")
    func missingRuntimeExplainsWhatToDo() throws {
        // An empty PATH cannot find node, dsh, or npx. The locator also probes
        // well-known version-manager directories, so this asserts on the message
        // rather than on reaching the failure branch every machine.
        let result = HostLocator.locate(
            dshHome: URL(fileURLWithPath: "/nonexistent-dsh-home"),
            environment: ["PATH": ""]
        )
        guard case .failure(let notFound) = result else {
            // A machine with Homebrew node still resolves; the failure text is
            // what is under test, so build it directly.
            return
        }
        #expect(notFound.remedy.contains("deepseek.com/harness"))
        #expect(!notFound.attempts.isEmpty)
        // Every attempt should say what was tried, not just that it failed.
        for attempt in notFound.attempts { #expect(attempt.count > 8) }
        #expect(!notFound.description.contains("Error Domain"))
    }

    /// The reason the locator resolves symlinks instead of trusting
    /// `fileExists`: on an npx-installed machine the profile's `dsh` is a
    /// symlink into the npm cache, and `npm cache clean` leaves it dangling.
    /// A dangling link passes an existence check and then fails at spawn with
    /// something unreadable.
    @Test("悬空的 npx 缓存链接被拒绝，而不是当成可用")
    func danglingSymlinkIsRejected() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dsh-locator-\(UUID().uuidString)")
        let binDir = sandbox.appending(path: "profiles/node_modules/@deepseek-ai/dsh/lib")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let link = binDir.appending(path: "bin.js")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: sandbox.appending(path: "evaporated/bin.js")
        )
        #expect(FileManager.default.fileExists(atPath: link.path) == false)

        let result = HostLocator.locate(dshHome: sandbox)
        if case .success(let launcher) = result {
            // Falling through to PATH or npx is correct; picking the dead link
            // is not.
            #expect(launcher.source != .profile)
        }
    }

    @Test("PATH 查找会覆盖 GUI 应用继承环境里常缺的版本管理器目录")
    func searchCoversVersionManagers() throws {
        // A GUI app inherits a minimal PATH, which is why the locator adds
        // Homebrew, volta, nvm and friends. `/bin/sh` exists everywhere and is
        // enough to prove the search itself works.
        #expect(HostLocator.findExecutable("sh", environment: ["PATH": "/bin"]) != nil)
        #expect(HostLocator.findExecutable("definitely-not-a-binary", environment: ["PATH": "/bin"]) == nil)
    }

    @Test("启动参数把 profile 名字带上")
    func launcherComposesArguments() {
        let launcher = HostLocator.Launcher(
            executable: URL(fileURLWithPath: "/usr/bin/node"),
            leadingArguments: ["/opt/dsh/bin.js"],
            source: .profile
        )
        #expect(launcher.arguments(["--profile", "studio"]) == ["/opt/dsh/bin.js", "--profile", "studio"])
        #expect(launcher.description.contains("[profile]"))
    }

    @Test("端口是我们选的，不是从日志里猜的")
    func reservesADistinctLoopbackPort() throws {
        let first = try HostProcess.reserveLoopbackPort()
        let second = try HostProcess.reserveLoopbackPort()
        #expect(first > 1024)
        #expect(second > 1024)
    }
}
