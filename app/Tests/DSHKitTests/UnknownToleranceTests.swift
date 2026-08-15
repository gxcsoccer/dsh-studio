import Foundation
import Testing

@testable import DSHKit

/// The other half of the codegen contract.
///
/// Unknown *fields* must break the build — that is why types are generated. But
/// unknown *values* must not break the app: the harness is merge-extensible by
/// design, so a plugin adding a tool kind, an event type, or a frame variant is
/// normal operation, not corruption. A client that throws on those is a client
/// that breaks every time somebody installs a plugin.
///
/// These tests use hand-written future-shaped payloads on purpose: the whole
/// point is traffic today's runtime cannot produce.
struct UnknownToleranceTests {
    let decoder = JSONDecoder()

    @Test("未知的帧种类被收进 .unknown 而不是抛错")
    func unknownFrameKind() throws {
        let line = Data(
            #"""
            {"type":"server-request","rpcId":"r1","method":"session/telepathy","payload":{"type":"session/telepathy","sessionId":"s1","thought":"hello"}}
            """#.utf8
        )
        let envelope = try MuxStream.decode(line)
        guard case .unknown(let raw) = envelope.frame else {
            Issue.record("应当落进 .unknown")
            return
        }
        // Carried, not discarded: a client should be able to log what it skipped.
        #expect(raw["thought"]?.stringValue == "hello")
        #expect(envelope.rpcId == "r1")
    }

    @Test("未知的枚举值保留原文而不是抛错")
    func unknownEnumCase() throws {
        let outcome = try decoder.decode(
            MuxFrameApprovalResolvedOutcome.self, from: Data(#""deferred-to-tuesday""#.utf8)
        )
        #expect(outcome == .unknown("deferred-to-tuesday"))
        #expect(outcome.rawValue == "deferred-to-tuesday")

        // And it survives a round trip, so relaying it does not corrupt it.
        let reencoded = try JSONEncoder().encode(outcome)
        #expect(String(decoding: reencoded, as: UTF8.self) == #""deferred-to-tuesday""#)
    }

    /// `SessionEvent.data` is `unknown` in the schema on purpose: per-type
    /// payloads live in `SessionEventMap`, extended by declaration merging
    /// across two dozen packages. An event type this build has never heard of
    /// must still fold into the transcript.
    @Test("未知的会话事件类型照常解码，data 原样保留")
    func unknownSessionEventType() throws {
        let line = Data(
            #"""
            {"type":"server-request","rpcId":"r2","method":"session/event","payload":{"type":"session/event","sessionId":"s1","event":{"type":"plugin/invented","seq":42,"time":1,"data":{"answer":42}}}}
            """#.utf8
        )
        guard case .sessionEvent(let payload) = try MuxStream.decode(line).frame else {
            Issue.record("应当仍是 session/event")
            return
        }
        #expect(payload.event.type == "plugin/invented")
        #expect(payload.event.seq == 42)
        #expect(payload.event.data["answer"] == .number(42))
    }

    /// Swift's synthesized decoding ignores unrecognized keys, which is what
    /// makes an additive upstream change non-breaking. Worth pinning, because
    /// a hand-written decoder would be the thing that loses it.
    @Test("已知帧上多出来的字段不影响解码")
    func additiveFieldsAreIgnored() throws {
        let line = Data(
            #"""
            {"type":"server-request","rpcId":"r3","method":"session/subscribed","payload":{"type":"session/subscribed","sessionId":"s1","lastSeq":7,"futureField":{"nested":true}}}
            """#.utf8
        )
        guard case .sessionSubscribed(let payload) = try MuxStream.decode(line).frame else {
            Issue.record("应当仍是 session/subscribed")
            return
        }
        #expect(payload.sessionId == "s1")
        #expect(payload.lastSeq == 7)
    }

    /// A client may only answer `allowed-once` or `rejected`; `cancelled` and
    /// `unavailable` are host-side outcomes. The Swift decision type has no way
    /// to express them, and this pins the wire spelling of the two it has.
    @Test("客户端只能给出两种审批结果")
    func approvalDecisionsAreConstrained() throws {
        #expect(ApprovalDecision.allowOnce.wireValue.rawValue == "allowed-once")
        #expect(ApprovalDecision.reject.wireValue.rawValue == "rejected")
    }
}
