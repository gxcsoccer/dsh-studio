import Foundation
import Testing

@testable import DSHKit

/// Replays a recorded downlink through the real decoder.
///
/// This is the check nothing else performs. Codegen proves the Swift types match
/// the *schemas*; `dsh-probe` proves one happy path runs against a live host.
/// Neither notices when the runtime emits a shape the generated types cover only
/// by falling back to `.unknown` — which is silent, by design, because unknown
/// tolerance is what keeps a merge-extensible contract from crashing the client.
///
/// Re-record with `tools/record-fixtures/record.mjs` after an upstream bump.
struct FixtureDecodingTests {
    static let lines: [Data] = {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/mux-session.jsonl")
        let text = (try? String(contentsOf: fixture, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { Data($0.utf8) }
    }()

    @Test("录制的每一帧都能解码")
    func everyFrameDecodes() throws {
        #expect(!Self.lines.isEmpty, "fixture 是空的 —— 先跑 tools/record-fixtures/record.mjs")
        for (index, line) in Self.lines.enumerated() {
            #expect(throws: Never.self, "第 \(index) 行解码失败") {
                try MuxStream.decode(line)
            }
        }
    }

    /// The assertion that actually detects upstream drift: a frame the runtime
    /// sends today must land in a named branch, not in the tolerance branch.
    @Test("没有任何一帧落进 .unknown")
    func noFrameFallsBackToUnknown() throws {
        var strays: [String] = []
        for line in Self.lines {
            guard case .unknown(let raw) = try MuxStream.decode(line).frame else { continue }
            strays.append(raw["type"]?.stringValue ?? raw.compactDescription.prefix(80).description)
        }
        #expect(
            strays.isEmpty,
            "运行时发来了生成类型不认识的帧：\(Set(strays).sorted()) —— 重跑 codegen"
        )
    }

    /// Guards the fixture itself. A recording taken from a trivial session would
    /// pass every test above while covering none of the interesting frames, so
    /// the fixture has to prove it exercised the hard paths.
    @Test("fixture 覆盖了值得覆盖的帧型")
    func fixtureIsRepresentative() throws {
        var seen: Set<String> = []
        for line in Self.lines {
            switch try MuxStream.decode(line).frame {
            case .sessionEvent: seen.insert("session/event")
            case .sessionSubscribed: seen.insert("session/subscribed")
            case .sessionProjection: seen.insert("session/projection")
            case .sessionQueue: seen.insert("session/queue")
            case .sessionJobs: seen.insert("session/jobs")
            case .approvalRequested: seen.insert("approval/requested")
            case .approvalResolved: seen.insert("approval/resolved")
            case .questionRequested: seen.insert("question/requested")
            case .questionResolved: seen.insert("question/resolved")
            case .streamError: seen.insert("stream/error")
            case .unknown: break
            }
        }
        // Deliberately not every kind: `stream/error` and the question frames
        // need failures and `ask_user` to provoke, which a recording script
        // should not manufacture. These five are what a normal turn must produce.
        let required = ["session/event", "session/subscribed", "session/projection",
                        "approval/requested", "approval/resolved"]
        for kind in required {
            #expect(seen.contains(kind), "fixture 里没有 \(kind) —— 这份录制没走过审批路径，不足以当回归基线")
        }
    }

    /// An approval frame is answerable, and answering it requires its rpcId
    /// verbatim. If that ever decodes as empty the agent waits forever, and the
    /// symptom is a session that looks merely slow.
    @Test("审批帧带得出可应答所需的 rpcId 与上下文")
    func approvalCarriesWhatAnAnswerNeeds() throws {
        let approvals = try Self.lines.compactMap { try MuxStream.decode($0).pendingApproval }
        let approval = try #require(approvals.first)

        #expect(!approval.rpcId.isEmpty)
        #expect(!approval.request.approvalId.isEmpty)
        #expect(approval.toolName == "bash")
        // The card cannot be honest without it; see docs/product.md.
        #expect(approval.reason?.isEmpty == false)
    }

    /// Chunked assistant output arrives packed, and the packed rows are not
    /// `SessionEventMap` members. Decoding must survive them rather than treat
    /// the stream as corrupt.
    @Test("流式分片行不会破坏解码")
    func packedChunkRowsSurvive() throws {
        var chunkEvents = 0
        for line in Self.lines {
            guard case .sessionEvent(let payload) = try MuxStream.decode(line).frame else { continue }
            if payload.event.type.contains("chunk") { chunkEvents += 1 }
        }
        #expect(chunkEvents > 0, "fixture 里没有任何 chunk 事件，流式路径未被覆盖")
    }

    /// Round-tripping through Swift catches an encoder that disagrees with its
    /// own decoder — which would only surface later as an answer the host
    /// rejects.
    @Test("解码后再编码再解码保持等价")
    func decodeEncodeDecodeIsStable() throws {
        let encoder = JSONEncoder()
        for line in Self.lines.prefix(200) {
            let first = try MuxStream.decode(line)
            let reencoded = try encoder.encode(first.frame)
            let second = try JSONDecoder().decode(MuxFrame.self, from: reencoded)
            #expect(first.frame == second)
        }
    }
}
