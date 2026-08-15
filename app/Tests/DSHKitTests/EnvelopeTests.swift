import Foundation
import Testing

@testable import DSHKit

/// The four-quadrant envelope, pinned.
///
/// These invariants are not ours to choose — they are the contract's, and every
/// one of them fails in a way that is hard to read from the outside: a wrong
/// `type` literal looks like an unknown method, a minted rpcId on a response
/// looks like the host ignoring you, and treating a 200 as success loses the
/// error entirely.
struct EnvelopeTests {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    @Test("client-request 的线上形状")
    func requestShape() throws {
        let payload = SessionCreateRequest(cwd: "/tmp/x")
        let data = try encoder.encode(
            OutboundRequest(rpcId: "rpc-1", method: "session.create", payload: payload)
        )
        let wire = try decoder.decode(JSONValue.self, from: data)

        #expect(wire["type"]?.stringValue == "client-request")
        #expect(wire["rpcId"]?.stringValue == "rpc-1")
        #expect(wire["method"]?.stringValue == "session.create")
        #expect(wire["payload"]?["cwd"]?.stringValue == "/tmp/x")
    }

    /// An answer is a *backfill* of the server-request's id. Minting a new one
    /// here would leave the host's promise pending forever while the client
    /// believes it answered.
    @Test("client-response 回显 rpcId 且把载荷放进 result.value")
    func responseShape() throws {
        let data = try encoder.encode(
            OutboundResponse(
                rpcId: "server-minted-7",
                payload: ApprovalResponsePayload(
                    sessionId: "s1", approvalId: "a1", outcome: .allowedOnce
                )
            )
        )
        let wire = try decoder.decode(JSONValue.self, from: data)

        #expect(wire["type"]?.stringValue == "client-response")
        #expect(wire["rpcId"]?.stringValue == "server-minted-7")
        #expect(wire["result"]?["ok"] == .bool(true))
        #expect(wire["result"]?["value"]?["approvalId"]?.stringValue == "a1")
        #expect(wire["result"]?["value"]?["outcome"]?.stringValue == "allowed-once")
    }

    @Test("成功响应解出业务值")
    func successfulResponse() throws {
        let body = Data(
            #"{"type":"server-response","rpcId":"r1","result":{"ok":true,"value":{"sessionId":"s9"}}}"#
                .utf8
        )
        let reply = try decoder.decode(InboundResponse<SessionCreateValue>.self, from: body)
        #expect(reply.rpcId == "r1")
        #expect(try reply.outcome.get().sessionId == "s9")
    }

    /// Business failures ride an HTTP 200. A client that keys success off the
    /// status code reports "it worked" for every rejected call.
    @Test("业务错误也是成功的 HTTP 响应，但不是成功的结果")
    func businessErrorIsNotSuccess() throws {
        let body = Data(
            #"""
            {"type":"server-response","rpcId":"r2","result":{"ok":false,"error":{"code":"session-not-found","message":"no such session","details":{"sessionId":"gone"}}}}
            """#.utf8
        )
        let reply = try decoder.decode(InboundResponse<SessionCreateValue>.self, from: body)
        #expect(reply.rpcId == "r2")
        #expect(throws: RpcFailure.self) { try reply.outcome.get() }
    }

    /// Four methods have void-shaped values (`credentials.set`,
    /// `credentials.unset`, `agentPreset.openDocument`, `agentPreset.remove`)
    /// and omit the slot entirely. Reading that as failure would make every one
    /// of them look broken.
    @Test("空返回类型允许缺失 value 槽")
    func voidShapedValueMaterializes() throws {
        let body = Data(#"{"type":"server-response","rpcId":"r3","result":{"ok":true}}"#.utf8)
        let reply = try decoder.decode(InboundResponse<CredentialsSetValue>.self, from: body)
        #expect(throws: Never.self) { try reply.outcome.get() }
    }

    /// For everything else an absent slot is a contract violation. It has to
    /// fail, and it has to say what actually happened — a bare `keyNotFound`
    /// reads like a missing field in the payload and sends the reader looking
    /// in the wrong place entirely.
    @Test("非空返回类型缺 value 槽时，报错说清楚是缺槽")
    func absentValueSlotIsReportedAsSuch() throws {
        let body = Data(#"{"type":"server-response","rpcId":"r4","result":{"ok":true}}"#.utf8)
        do {
            _ = try decoder.decode(InboundResponse<SessionCancelValue>.self, from: body)
            Issue.record("应当抛错")
        } catch {
            #expect("\(error)".contains("result.value"))
        }
    }

    @Test("每个方法都知道自己的 wire 名字")
    func methodsAreWired() {
        #expect(SessionCreateRequest.wireMethod.rawValue == "session.create")
        #expect(SessionPromptRequest.wireMethod.rawValue == "session.prompt")
        #expect(SessionCancelRequest.wireMethod.rawValue == "session.cancel")
        #expect(HostDescribeRequest.wireMethod.rawValue == "host.describe")
        // The generated table is the contract's, so its size is a fact worth
        // pinning: a method quietly disappearing would otherwise go unnoticed.
        #expect(WireMethod.allCases.count == 52)
    }

    /// `session.cancel` and `session.models` both take `{ sessionId }`. If
    /// structural deduplication ever collapses them again they cannot carry
    /// different response types, and this stops compiling.
    @Test("形状相同的请求仍是不同类型")
    func identicallyShapedRequestsStayDistinct() {
        #expect(SessionCancelRequest.Response.self != SessionModelsRequest.Response.self)
    }
}
