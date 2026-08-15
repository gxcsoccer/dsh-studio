import DSHKit
import Foundation

/// Owns a child `dsh` process: start it, wait until it actually answers, and
/// stop it without leaving an orphan holding a port.
///
/// The port is chosen by us and passed in, never scraped from the child's
/// stdout. The bind address is ours to decide, so reading it back out of a log
/// line turns a known fact into a guess — and that guess is what forces the
/// `127.0.0.1` vs `localhost` retry dance seen in earlier desktop attempts.
public actor HostProcess {
    public struct Failure: Error, CustomStringConvertible {
        public let summary: String
        public let output: String

        public var description: String {
            output.isEmpty ? summary : "\(summary)\n--- dsh 输出 ---\n\(output)"
        }
    }

    private let process = Process()
    private let capture = Pipe()
    private let transcript = Transcript()

    public nonisolated let baseURL: URL
    public nonisolated let launcher: HostLocator.Launcher

    /// - Parameters:
    ///   - port: where the surface is expected to answer. For the `studio`
    ///     profile this is pinned in the bundle patch, not passed as a flag:
    ///     the profile mounts no command-line app, so there is nothing to parse
    ///     `--port`. Flags belong to `profileArguments` only when the composed
    ///     profile actually has an app that reads them (`web` does).
    public init(
        launcher: HostLocator.Launcher,
        profile: String = "studio",
        port: UInt16,
        profileArguments: [String] = [],
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.launcher = launcher
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!

        process.executableURL = launcher.executable
        process.arguments = launcher.arguments(["--profile", profile] + profileArguments)
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = capture
        process.standardError = capture
    }

    /// Starts the child and returns once it answers `host.describe`, which is a
    /// stronger readiness signal than "the port accepts connections": it proves
    /// the whole plugin tree booted, not just the webserver row.
    public func start(timeout: Duration = .seconds(60)) async throws {
        let sink = transcript
        capture.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { Task { await sink.append(String(decoding: chunk, as: UTF8.self)) } }
        }

        do {
            try process.run()
        } catch {
            throw Failure(summary: "起不来 \(launcher): \(error.localizedDescription)", output: await transcript.text)
        }

        let client = ApiClient(baseURL: baseURL)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                throw Failure(
                    summary: "dsh 在就绪前退出了（exit \(process.terminationStatus)）",
                    output: await transcript.text
                )
            }
            if (try? await client.call(HostDescribeRequest())) != nil { return }
            try? await Task.sleep(for: .milliseconds(200))
        }

        await stop()
        throw Failure(summary: "等了 \(timeout) 仍未就绪", output: await transcript.text)
    }

    /// SIGTERM, then SIGKILL. The child owns a listening socket and session
    /// writers; killing it outright risks a half-written log, so it gets a
    /// chance to close first.
    public func stop(graceBeforeKill: Duration = .seconds(5)) async {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = ContinuousClock.now.advanced(by: graceBeforeKill)
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }

        capture.fileHandleForReading.readabilityHandler = nil
    }

    public func output() async -> String { await transcript.text }

    /// Picks a free loopback port by binding one and releasing it. Racy in
    /// principle; a lost race surfaces as a clean `EADDRINUSE` at launch rather
    /// than as a mystery, which is the trade we want against scraping stdout.
    public static func reserveLoopbackPort() throws -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw Failure(summary: "socket() 失败", output: "") }
        defer { close(handle) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw Failure(summary: "bind() 失败", output: "") }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else { throw Failure(summary: "getsockname() 失败", output: "") }
        return UInt16(bigEndian: assigned.sin_port)
    }
}

/// Child output is written from a file-handle callback and read from async
/// code; an actor is the cheap way to keep that legal.
private actor Transcript {
    private var buffer = ""
    func append(_ chunk: String) { buffer += chunk }
    var text: String { buffer }
}
