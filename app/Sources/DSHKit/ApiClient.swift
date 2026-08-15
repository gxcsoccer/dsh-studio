import Foundation

/// The one thing that differs between carriers.
///
/// Upstream draws the same line: `AbstractApiClient` keeps every protocol
/// invariant and leaves exactly one abstract method, `doFetch` — "browser
/// fetch, injected handler.fetch, IPC bridge, ...". Mirroring that split means
/// M4's move from the official web carrier to our own Unix domain socket
/// carrier replaces this one conformance and nothing above it.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CarrierError.notAnEnvelope("no HTTP response")
        }
        return (data, http)
    }
}

/// The Swift face of the official ApiProxy contract — the counterpart of
/// upstream's `AbstractApiClient`, holding the same protocol invariants:
/// rpcId minting, envelope wrap/unwrap, echo verification, and typed decoding.
///
/// Everything here is written against the contract, not the pipe.
public actor ApiClient {
    private let baseURL: URL
    private let transport: any Transport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, transport: any Transport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public init(baseURL: URL, session: URLSession = .shared) {
        self.init(baseURL: baseURL, transport: URLSessionTransport(session: session))
    }

    public nonisolated var endpoint: URL { baseURL }

    /// Unary call: mint → wrap → POST → unwrap → verify echo → decode.
    public func call<Request: WireRequest>(_ request: Request) async throws -> Request.Response {
        let method = Request.wireMethod.rawValue
        let rpcId = RpcIdentifier.mint()
        let body = try encoder.encode(OutboundRequest(rpcId: rpcId, method: method, payload: request))

        let data = try await post(path: "/api/\(method)", body: body)
        let reply = try decoder.decode(InboundResponse<Request.Response>.self, from: data)
        guard reply.rpcId == rpcId else {
            throw CarrierError.rpcIdMismatch(sent: rpcId, received: reply.rpcId)
        }
        return try reply.outcome.get()
    }

    /// Answers an answerable server-request (`approval/requested`,
    /// `question/requested`). The rpcId is a backfill of the frame's own id —
    /// never minted here — and answering is what keeps the agent from waiting
    /// forever.
    @discardableResult
    public func respond(to rpcId: RpcId, with payload: some Encodable & Sendable) async throws -> RpcReceipt {
        let body = try encoder.encode(OutboundResponse(rpcId: rpcId, payload: payload))
        let data = try await post(path: "/api/respond", body: body)
        return try decoder.decode(RpcReceipt.self, from: data)
    }

    private func post(path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, http) = try await transport.send(request)
        // Business errors ride a 200 with `ok: false`. A non-2xx means the
        // request never reached a handler at all.
        guard (200..<300).contains(http.statusCode) else {
            throw CarrierError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
