import Foundation

/// 数据通道 RPC 方法名。
///
/// 取值域 = 官方 `RpcMethodMap`（`packages/host/apiproxy/src/api/rpc-map.ts`）。
/// bridge-contract.md §2.2：**我们不在这里加自己的方法** —— 加了就是在造一套
/// 影子 API，上游一改就全断。Studio 自己的需求走 `/studio/*` 前缀。
public struct RPCMethod: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // W1 需要的子集（全部实读自上游 rpc-map.ts）
    public static let sessionList = RPCMethod(rawValue: "session.list")
    public static let sessionSearch = RPCMethod(rawValue: "session.search")
    public static let sessionCreate = RPCMethod(rawValue: "session.create")
    public static let sessionHistory = RPCMethod(rawValue: "session.history")
    public static let sessionRename = RPCMethod(rawValue: "session.rename")
    public static let sessionCancel = RPCMethod(rawValue: "session.cancel")
    public static let sessionPrompt = RPCMethod(rawValue: "session.prompt")
    public static let workspaceList = RPCMethod(rawValue: "workspace.list")
    public static let workspaceCreate = RPCMethod(rawValue: "workspace.create")
    public static let workspaceRename = RPCMethod(rawValue: "workspace.rename")
    public static let workspaceArchiveSession = RPCMethod(rawValue: "workspace.archiveSession")
    public static let workspaceInsertSessionBefore = RPCMethod(rawValue: "workspace.insertSessionBefore")
    public static let hostDescribe = RPCMethod(rawValue: "host.describe")
    public static let hostPickDirectory = RPCMethod(rawValue: "host.pickDirectory")

    /// 转发面卫兵：`/rpc` 只转发官方方法。任何 `studio.*` 都是我们自己发明的
    /// 语义，必须走 `/studio/*`，否则就是在官方 API 面上造影子方法。
    public var isForwardable: Bool {
        !rawValue.isEmpty
            && !rawValue.hasPrefix("studio.")
            && rawValue.contains(".")
    }
}

/// `POST /rpc` 的请求体（bridge-contract.md §2.2）。
public struct RPCRequestBody<Params: Encodable & Sendable>: Encodable, Sendable {
    public let method: RPCMethod
    public let params: Params

    public init(method: RPCMethod, params: Params) {
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case method, params
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method.rawValue, forKey: .method)
        try container.encode(params, forKey: .params)
    }
}

/// 空参数（上游多数 list 方法是 `{}`）。
public struct EmptyParams: Encodable, Sendable {
    public init() {}
    public func encode(to encoder: any Encoder) throws {
        // 编码成 `{}`：只要开一个 keyed container 就够了。
        _ = encoder.container(keyedBy: JSONCodingKey.self)
    }
}

struct JSONCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.intValue = intValue
        stringValue = String(intValue)
    }
}

/// RPC 故障（转发官方 `RpcError` 的可用形状）。
///
/// ⚠️ 契约缺口：bridge-contract.md §2.2 只规定了 `/rpc` 的**请求**体，
/// 没有规定响应包装。这里采用 `{ ok, value | error }` 并对「裸值」做兼容
/// 解码（见 `RPCReply`），把这个假设集中在一处而不是散在各处。
public struct RPCFault: Error, Hashable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }

    public static func decode(_ value: JSONValue) -> RPCFault {
        RPCFault(
            code: value["code"]?.stringValue ?? "unknown",
            message: String((value["message"]?.stringValue ?? value.description).prefix(4096))
        )
    }
}

/// `/rpc` 响应的解包。
public enum RPCReply {
    /// `{ ok:true, value }` / `{ ok:false, error }` / 裸值三种形态都能吃。
    public static func unwrap(_ value: JSONValue) throws -> JSONValue {
        guard let fields = value.objectValue else { return value }
        if let ok = fields["ok"]?.boolValue {
            if ok {
                return fields["value"] ?? fields["result"] ?? .object([:])
            }
            throw RPCFault.decode(fields["error"] ?? .null)
        }
        if let error = fields["error"], !error.isNull {
            throw RPCFault.decode(error)
        }
        return value
    }
}
