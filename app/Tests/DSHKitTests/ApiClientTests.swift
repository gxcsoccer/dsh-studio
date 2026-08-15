import Foundation
import Testing

@testable import DSHKit

/// A transport that answers from a script and remembers what it was asked.
///
/// The point is to reach the parts of the call path a live host cannot exercise
/// on demand: an echoed id that does not match, a carrier-level HTTP failure, a
/// malformed envelope. Those are precisely the failures that are impossible to
/// provoke in a probe run and miserable to diagnose in the field.
final class ScriptedTransport: Transport, @unchecked Sendable {
    struct Exchange: Sendable {
        let url: URL
        let method: String?
        let body: JSONValue?
    }

    private(set) var exchanges: [Exchange] = []
    private let respond: @Sendable (URLRequest) -> (Data, Int)

    init(respond: @escaping @Sendable (URLRequest) -> (Data, Int)) {
        self.respond = respond
    }

    /// Answers every call with one canned body, echoing back whatever rpcId the
    /// client minted — the normal-path fake.
    static func echoing(value: String) -> ScriptedTransport {
        ScriptedTransport { request in
            let sent = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let rpcId = (sent?["rpcId"] as? String) ?? ""
            let body = """
                {"type":"server-response","rpcId":"\(rpcId)","result":{"ok":true,"value":\(value)}}
                """
            return (Data(body.utf8), 200)
        }
    }

    static func replying(_ body: String, status: Int = 200) -> ScriptedTransport {
        ScriptedTransport { _ in (Data(body.utf8), status) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        exchanges.append(
            Exchange(
                url: request.url!,
                method: request.httpMethod,
                body: request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            )
        )
        let (data, status) = respond(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }
}

struct ApiClientTests {
    let base = URL(string: "http://127.0.0.1:9999")!

    @Test("一元调用打到 /api/<method>，并带上完整信封")
    func unaryCallShape() async throws {
        let transport = ScriptedTransport.echoing(value: #"{"sessionId":"s1"}"#)
        let client = ApiClient(baseURL: base, transport: transport)

        let value = try await client.call(SessionCreateRequest(cwd: "/tmp/w"))
        #expect(value.sessionId == "s1")

        let sent = try #require(transport.exchanges.first)
        #expect(sent.url.path == "/api/session.create")
        #expect(sent.method == "POST")
        #expect(sent.body?["type"]?.stringValue == "client-request")
        #expect(sent.body?["method"]?.stringValue == "session.create")
        #expect(sent.body?["payload"]?["cwd"]?.stringValue == "/tmp/w")
        #expect(sent.body?["rpcId"]?.stringValue?.isEmpty == false)
    }

    @Test("每次调用铸一个新的 rpcId")
    func rpcIdsAreFresh() async throws {
        let transport = ScriptedTransport.echoing(value: #"{"sessionId":"s1"}"#)
        let client = ApiClient(baseURL: base, transport: transport)

        _ = try await client.call(SessionCreateRequest())
        _ = try await client.call(SessionCreateRequest())

        let ids = transport.exchanges.compactMap { $0.body?["rpcId"]?.stringValue }
        #expect(ids.count == 2)
        #expect(ids[0] != ids[1])
    }

    /// The failure a live host will never hand you, and the one with the worst
    /// consequence: taking a response as the answer to a different request.
    @Test("回显的 rpcId 对不上就拒绝，不能张冠李戴")
    func mismatchedEchoIsRejected() async throws {
        let transport = ScriptedTransport.replying(
            #"{"type":"server-response","rpcId":"somebody-elses","result":{"ok":true,"value":{"sessionId":"s1"}}}"#
        )
        let client = ApiClient(baseURL: base, transport: transport)

        await #expect(throws: CarrierError.self) {
            _ = try await client.call(SessionCreateRequest())
        }
    }

    @Test("非 2xx 是载体层失败，附带原始响应体")
    func carrierFailureCarriesTheBody() async throws {
        let transport = ScriptedTransport.replying("forbidden", status: 403)
        let client = ApiClient(baseURL: base, transport: transport)

        do {
            _ = try await client.call(HostPickDirectoryRequest())
            Issue.record("应当抛错")
        } catch let error as CarrierError {
            guard case .http(let status, let body) = error else {
                Issue.record("应当是 .http，实际 \(error)")
                return
            }
            #expect(status == 403)
            #expect(body == "forbidden")
        }
    }

    /// Business failures arrive on a 200. The echo has to match, or the client
    /// would reject the response before ever reading the error — so this fake
    /// echoes properly and fails only at the business layer.
    @Test("业务错误抛 RpcFailure，而不是被当成成功")
    func businessErrorSurfaces() async throws {
        let transport = ScriptedTransport { request in
            let sent = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let rpcId = (sent?["rpcId"] as? String) ?? ""
            let body = """
                {"type":"server-response","rpcId":"\(rpcId)","result":{"ok":false,\
                "error":{"code":"session-not-found","message":"gone","details":{"sessionId":"s404"}}}}
                """
            return (Data(body.utf8), 200)
        }
        let client = ApiClient(baseURL: base, transport: transport)

        await #expect(throws: RpcFailure.self) {
            _ = try await client.call(SessionCancelRequest(sessionId: "s404"))
        }
    }

    /// Answering is the difference between a turn that continues and a turn
    /// that hangs, so the wire shape of an answer is worth pinning at the
    /// client level too, not just at the encoder level.
    @Test("批准一次会 POST /api/respond 并回显那一帧的 rpcId")
    func approvalIsAnsweredOnTheFrameId() async throws {
        let transport = ScriptedTransport.replying(#"{"accepted":true}"#)
        let client = ApiClient(baseURL: base, transport: transport)

        let approval = PendingApproval(
            rpcId: "frame-77",
            request: MuxFrameApprovalRequested(
                type: "approval/requested",
                sessionId: "s1",
                approvalId: "a1",
                toolName: "bash",
                reason: "escalate"
            )
        )
        _ = try await client.decide(approval, .allowOnce)

        let sent = try #require(transport.exchanges.first)
        #expect(sent.url.path == "/api/respond")
        #expect(sent.body?["type"]?.stringValue == "client-response")
        // Echoed, never minted: a fresh id here leaves the host waiting forever.
        #expect(sent.body?["rpcId"]?.stringValue == "frame-77")
        #expect(sent.body?["result"]?["value"]?["outcome"]?.stringValue == "allowed-once")
        #expect(sent.body?["result"]?["value"]?["approvalId"]?.stringValue == "a1")
    }

    @Test("拒绝走同一条路径，只是结果不同")
    func rejectionUsesTheSamePath() async throws {
        let transport = ScriptedTransport.replying(#"{"accepted":true}"#)
        let client = ApiClient(baseURL: base, transport: transport)

        let approval = PendingApproval(
            rpcId: "frame-88",
            request: MuxFrameApprovalRequested(
                type: "approval/requested", sessionId: "s1", approvalId: "a2", toolName: "bash"
            )
        )
        _ = try await client.decide(approval, .reject)

        let sent = try #require(transport.exchanges.first)
        #expect(sent.body?["rpcId"]?.stringValue == "frame-88")
        #expect(sent.body?["result"]?["value"]?["outcome"]?.stringValue == "rejected")
    }

    @Test("回答提问同样回显帧的 rpcId")
    func questionAnswerEchoesFrameId() async throws {
        let transport = ScriptedTransport.replying(#"{"accepted":true}"#)
        let client = ApiClient(baseURL: base, transport: transport)

        let question = PendingQuestion(
            rpcId: "frame-99",
            request: MuxFrameQuestionRequested(type: "question/requested", sessionId: "s1", questions: [])
        )
        _ = try await client.answer(
            question, with: [AskUserQuestionAnswerAnswersItem(id: "q1", selected: ["yes"])]
        )

        let sent = try #require(transport.exchanges.first)
        #expect(sent.url.path == "/api/respond")
        #expect(sent.body?["rpcId"]?.stringValue == "frame-99")
        #expect(sent.body?["result"]?["value"]?["answer"]?["answers"]?.compactDescription.contains("q1") == true)
    }

    @Test("响应不是信封时报载体错误，而不是解码错误")
    func malformedEnvelopeIsACarrierProblem() async throws {
        let transport = ScriptedTransport.replying("<html>not json</html>")
        let client = ApiClient(baseURL: base, transport: transport)

        await #expect(throws: (any Error).self) {
            _ = try await client.call(SessionCreateRequest())
        }
    }
}
