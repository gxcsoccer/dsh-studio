import Foundation

/// A request payload that knows which wire method carries it and what comes
/// back. Conformances are generated from `RpcMethodMap`, so this protocol is
/// the compile-time link between a Swift call and the official contract.
public protocol WireRequest: Encodable, Sendable {
    associatedtype Response: Decodable & Sendable
    static var wireMethod: WireMethod { get }
}

/// The four message kinds of the contract. Only the two the client originates
/// are constructed here; the two the host originates arrive already decoded.
enum WireKind {
    static let clientRequest = "client-request"
    static let clientResponse = "client-response"
}

/// Correlation id. The initiator mints it; a response echoes it and never
/// mints a new one.
public enum RpcIdentifier {
    public static func mint() -> RpcId { UUID().uuidString }
}

struct OutboundRequest<Payload: Encodable>: Encodable {
    let rpcId: RpcId
    let method: String
    let payload: Payload

    private enum CodingKeys: String, CodingKey { case type, rpcId, method, payload }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WireKind.clientRequest, forKey: .type)
        try container.encode(rpcId, forKey: .rpcId)
        try container.encode(method, forKey: .method)
        try container.encode(payload, forKey: .payload)
    }
}

struct OutboundResponse<Payload: Encodable>: Encodable {
    let rpcId: RpcId
    let payload: Payload

    private enum CodingKeys: String, CodingKey { case type, rpcId, result }
    private enum ResultKeys: String, CodingKey { case ok, value }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WireKind.clientResponse, forKey: .type)
        try container.encode(rpcId, forKey: .rpcId)
        var result = container.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
        try result.encode(true, forKey: .ok)
        try result.encode(payload, forKey: .value)
    }
}

/// A decoded `server-response`: the rpcId echo plus the ok/error result.
struct InboundResponse<Value: Decodable>: Decodable {
    let rpcId: RpcId
    let outcome: Result<Value, RpcFailure>

    private enum CodingKeys: String, CodingKey { case rpcId, result }
    private enum ResultKeys: String, CodingKey { case ok, value, error }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rpcId = try container.decode(RpcId.self, forKey: .rpcId)
        let result = try container.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)

        if try result.decode(Bool.self, forKey: .ok) {
            if result.contains(.value) {
                outcome = .success(try result.decode(Value.self, forKey: .value))
            } else {
                // Four methods have void-shaped values (`credentials.set` and
                // friends) and omit the slot entirely, so an empty object is the
                // right reading. For anything else an absent slot is a contract
                // violation, and the raw `keyNotFound` it produces reads like a
                // missing field in the payload — which sends whoever debugs it
                // looking in the wrong place.
                do {
                    outcome = .success(try JSONDecoder().decode(Value.self, from: Data("{}".utf8)))
                } catch {
                    throw CarrierError.notAnEnvelope(
                        "响应缺少 result.value，但 \(Value.self) 不是空返回类型（\(error)）"
                    )
                }
            }
        } else {
            outcome = .failure(RpcFailure(error: try result.decode(RpcError.self, forKey: .error)))
        }
    }
}

/// A business-level failure. It arrives on an HTTP 200 — status codes describe
/// only the carrier, never the operation.
public struct RpcFailure: Error, Sendable {
    public let error: RpcError
}

/// A carrier-level failure: the request never reached a handler, or the reply
/// was not a well-formed envelope.
public enum CarrierError: Error, Sendable {
    case http(status: Int, body: String)
    case rpcIdMismatch(sent: RpcId, received: RpcId)
    case streamClosed
    case notAnEnvelope(String)
}

extension RpcFailure: CustomStringConvertible {
    public var description: String {
        guard
            let data = try? JSONEncoder().encode(error),
            let text = String(data: data, encoding: .utf8)
        else { return "rpc error" }
        return text
    }
}
