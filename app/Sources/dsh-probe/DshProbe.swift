import DSHHost
import DSHKit
import Foundation

/// Acceptance harness for the Swift client.
///
/// It doubles as the project's smoke test. The gateway protocol has no version
/// negotiation — and nothing on the wire even reports the contract version —
/// so a probe run against a real host is the only way to learn that upstream
/// moved.
@main
struct DshProbe {
    static func main() async {
        let options = Options(arguments: CommandLine.arguments)
        do {
            switch options.scenario {
            case .locate: try locate()
            case .session: try await session(options, client: ApiClient(baseURL: options.baseURL))
            case .approval: try await approval(options, client: ApiClient(baseURL: options.baseURL))
            case .supervised: try await supervised(options)
            }
            print("\nPASS")
        } catch {
            FileHandle.standardError.write(Data("\nFAIL: \(describe(error))\n".utf8))
            exit(1)
        }
    }

    // ── locate: the "no dsh on PATH" path must produce an action, not a stack ──

    static func locate() throws {
        switch HostLocator.locate() {
        case .success(let launcher):
            print("launcher      \(launcher)")
        case .failure(let notFound):
            print(notFound.description)
            throw ProbeError.noLauncher
        }
    }

    // ── supervised: own the runtime lifecycle, then run the scenarios ─────────

    static func supervised(_ options: Options) async throws {
        let launcher = try HostLocator.locate().get()
        print("launcher      \(launcher)")

        // The probe drives the official `web` profile, whose app does parse
        // `--port`, so it can take a free one instead of the studio bundle's
        // pinned port and avoid colliding with a running desktop.
        let port = try HostProcess.reserveLoopbackPort()
        let host = HostProcess(
            launcher: launcher,
            profile: "web",
            port: port,
            profileArguments: ["--host", "127.0.0.1", "--port", String(port)],
            workingDirectory: URL(fileURLWithPath: options.cwd)
        )
        print("port          \(port)  (钉死，不从 stdout 抓)")

        do {
            try await host.start()
        } catch {
            print(await host.output().suffix(2000))
            throw error
        }
        print("ready         \(host.baseURL.absoluteString)")

        let client = ApiClient(baseURL: host.baseURL)
        var scenarioError: (any Error)?
        do {
            try await session(options, client: client)
            try await approval(options, client: client)
        } catch {
            scenarioError = error
        }

        await host.stop()
        print("\nstopped       子进程已优雅退出")
        if let scenarioError { throw scenarioError }
    }

    // ── session: the M0 path ─────────────────────────────────────────────────

    static func session(_ options: Options, client: ApiClient) async throws {
        print("\n── 会话往返 ──")
        let host = try await client.call(HostDescribeRequest())
        print("host app      \(host.version)  (apps/cli)")
        print("generated for \(generatedContractVersion)  (dsh-host-apiproxy)")
        print("model         \(host.provider ?? "?") / \(host.model ?? "?")")

        let frames = MuxStream.open(baseURL: client.endpoint)
        let created = try await client.call(SessionCreateRequest(cwd: options.cwd))
        print("session       \(created.sessionId)")

        _ = try await client.call(
            SessionPromptRequest(
                sessionId: created.sessionId,
                mode: .queue,
                content: [.text(SessionPromptRequestContentItemText(type: "text", text: options.prompt))]
            )
        )

        try await deadline(options.timeout) {
            for try await envelope in frames {
                guard case .sessionEvent(let payload) = envelope.frame,
                      payload.sessionId == created.sessionId else { continue }
                if payload.event.type == "assistant/chunk" {
                    print("assistant/chunk 到达 — 信封、方法分发、会话生命周期、流式解码全部走通")
                    return
                }
            }
            throw ProbeError.streamEndedEarly
        }
    }

    // ── approval: the M1 path ────────────────────────────────────────────────

    /// Proves the two properties that decide whether an agent ever gets stuck:
    ///
    ///   1. An answered approval unblocks the turn.
    ///   2. Dropping the stream without answering does not lose the request —
    ///      reopening replays it with the *same* rpcId, which is what makes
    ///      "quit the app mid-approval" recoverable rather than a wedged session.
    static func approval(_ options: Options, client: ApiClient) async throws {
        print("\n── 审批闭环 ──")
        let created = try await client.call(SessionCreateRequest(cwd: options.cwd))
        print("session       \(created.sessionId)")

        let opening = MuxStream.subscribe(baseURL: client.endpoint)
        _ = try await client.call(
            SessionPromptRequest(
                sessionId: created.sessionId,
                mode: .queue,
                content: [.text(SessionPromptRequestContentItemText(type: "text", text: options.escalatingPrompt))]
            )
        )
        print("prompt        \(options.escalatingPrompt.debugDescription)")

        // 1. Wait for the escalation, and deliberately do not answer it.
        let sessionId = created.sessionId
        let openingFrames = opening.frames
        let first = try await deadline(options.timeout) {
            try await firstApproval(in: openingFrames, sessionId: sessionId)
        }
        print("approval      tool=\(first.toolName)  rpcId=\(first.rpcId)")
        if let reason = first.reason { print("reason        \(reason)") }

        // 2. Drop the stream, as quitting the app would.
        opening.cancel()
        let reconnected = MuxStream.subscribe(baseURL: client.endpoint)
        let frames = reconnected.frames
        print("reconnect     重开下行，未应答的请求应当被原样重放")

        let replayed = try await deadline(.seconds(20)) {
            try await firstApproval(in: frames, sessionId: sessionId)
        }
        guard replayed.rpcId == first.rpcId else {
            throw ProbeError.rpcIdNotReplayed(first: first.rpcId, replayed: replayed.rpcId)
        }
        print("replayed      rpcId 逐字一致 — 断连不丢待决审批")

        // 3. Answer it, and require the turn to finish.
        try await client.decide(replayed, .allowOnce)
        print("decided       allowed-once")

        try await deadline(options.timeout) {
            for try await envelope in frames {
                if let pending = envelope.pendingApproval, pending.sessionId == created.sessionId {
                    // A tool may escalate more than once; keep the turn moving.
                    try await client.decide(pending, .allowOnce)
                    print("decided       allowed-once (再次升权 \(pending.toolName))")
                    continue
                }
                if let question = envelope.pendingQuestion, question.sessionId == created.sessionId {
                    print("question      \(question.questions.count) 个 — M1 不作答，仅证明可解码")
                    continue
                }
                guard case .sessionEvent(let payload) = envelope.frame,
                      payload.sessionId == created.sessionId else { continue }
                if payload.event.type == "turn/end" {
                    print("turn/end      应答之后这一轮跑完了 — 审批闭环成立")
                    return
                }
            }
            throw ProbeError.streamEndedEarly
        }
    }

    static func firstApproval(
        in frames: AsyncThrowingStream<MuxEnvelope, any Error>,
        sessionId: String,
        trace: Bool = false
    ) async throws -> PendingApproval {
        for try await envelope in frames {
            if let pending = envelope.pendingApproval, pending.sessionId == sessionId { return pending }
            guard case .sessionEvent(let payload) = envelope.frame,
                  payload.sessionId == sessionId else { continue }

            // Tool activity is what decides whether this scenario is even
            // exercising the approval path, so it is always worth showing.
            switch payload.event.type {
            case "tool/call", "tool/result", "approval/asked", "approval/decided":
                print("  \(String(format: "%4d", payload.event.seq))  \(payload.event.type)  \(summarize(payload.event.data))")
            case "assistant/message":
                print("  \(String(format: "%4d", payload.event.seq))  assistant  \(summarize(payload.event.data))")
            case "turn/end":
                throw ProbeError.noEscalation
            default:
                if trace { print("  \(String(format: "%4d", payload.event.seq))  \(payload.event.type)") }
            }
        }
        throw ProbeError.streamEndedEarly
    }

    static func summarize(_ data: JSONValue) -> String {
        String(data.compactDescription.prefix(220))
    }

    // ── plumbing ─────────────────────────────────────────────────────────────

    static func deadline<T: Sendable>(
        _ limit: Duration,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await Task.sleep(for: limit)
                throw ProbeError.timedOut(limit)
            }
            group.addTask { try await work() }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as RpcFailure: return "业务错误 \(failure)"
        case let failure as MuxStreamFailure: return "流中途失败 \(failure.error)"
        case let carrier as CarrierError: return "载体错误 \(carrier)"
        case let notFound as HostLocator.NotFound: return notFound.description
        case let host as HostProcess.Failure: return host.description
        case let probe as ProbeError: return probe.description
        default: return String(describing: error)
        }
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case timedOut(Duration)
    case streamEndedEarly
    case noLauncher
    case noEscalation
    case rpcIdNotReplayed(first: RpcId, replayed: RpcId)

    var description: String {
        switch self {
        case .timedOut(let after):
            return "等了 \(after) 没等到期望的帧"
        case .streamEndedEarly:
            return "下行流提前结束"
        case .noLauncher:
            return "没有可用的 dsh 运行时"
        case .noEscalation:
            return """
                这一轮没有触发升权就结束了，审批路径未被验证 —— 这不算通过。
                当前 permission preset 可能已经放行了该命令；换一个 --escalating-prompt 再试。
                """
        case .rpcIdNotReplayed(let first, let replayed):
            return "重连后 rpcId 变了（\(first) → \(replayed)）—— 应答会打在错误的请求上"
        }
    }
}

struct Options {
    enum Scenario: String { case locate, session, approval, supervised }

    var scenario = Scenario.session
    var baseURL = URL(string: "http://127.0.0.1:3080")!
    var cwd = FileManager.default.currentDirectoryPath
    var prompt = "Reply with exactly: pong. Do not use any tools."
    /// Must attempt a *write outside the session workspace*: `workspace-write`
    /// restricts modification, not reading, so `cat` of anything escalates
    /// nothing. The file is removed by the probe afterwards.
    var escalatingPrompt = """
        Run exactly this bash command and tell me whether it succeeded: \
        printf ok > "$HOME/.dsh-probe-m1.tmp"
        """
    var timeout = Duration.seconds(120)

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--url": if let v = iterator.next(), let url = URL(string: v) { baseURL = url }
            case "--cwd": if let v = iterator.next() { cwd = v }
            case "--prompt": if let v = iterator.next() { prompt = v }
            case "--escalating-prompt": if let v = iterator.next() { escalatingPrompt = v }
            case "--timeout": if let v = iterator.next(), let s = Int64(v) { timeout = .seconds(s) }
            default: if let parsed = Scenario(rawValue: flag) { scenario = parsed }
            }
        }
    }
}
