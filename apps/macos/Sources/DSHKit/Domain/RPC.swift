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
/// 响应包装不再是「我们的假设」：`/rpc` 由 bridge **逐字转发**上游
/// `toFetchHandler` 的回答（`bridge-server.ts handleRpc`：`response.end(text)`），
/// 所以线上真实形状就是上游 `ServerResponse`：
/// `{ type:"server-response", rpcId, result:{ ok:true, value } | { ok:false, error } }`
/// （上游 `rpc.schema.ts` 的 `serverResponseSchema` / `rpcResultSchema`）。见 `RPCReply`。
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
    /// 解包失败：我们**没读懂**对端的回答。
    ///
    /// 与 `RPCFault` 严格区分：`RPCFault` 是「读懂了，上游说这次业务失败」，
    /// 这个是「连信封都不认识」——版本/契约不一致，重试网络无用，必须画成
    /// 失败态（`DSHClient` 把它翻成 `.protocolBroken`）。
    public struct EnvelopeError: Error, Hashable, Sendable, CustomStringConvertible {
        public let detail: String
        public init(_ detail: String) { self.detail = detail }
        public var description: String { detail }
    }

    /// 吃官方信封 `{ type:"server-response", rpcId, result:{ ok, value|error } }`，
    /// 以及裸的 `result` 本体 `{ ok, value|error }`。
    ///
    /// ⚠️ **不要**再加「裸值兜底」。历史教训（known-gaps G-11）：这里曾经以
    /// `return value` 收尾，于是官方信封整个被当成业务值交给上层——
    /// `WorkspaceListValue` 在 `{type,rpcId,result}` 上找不到 `items`，配合当时
    /// 的 `try? … ?? []` 就静默变成「零个工作区」。侧栏于是在一个**完全健康**的
    /// runtime 上理直气壮显示「暂无会话」。宽容解析在这里不是鲁棒性，是把
    /// 「没读懂」伪装成「没数据」。
    public static func unwrap(_ value: JSONValue) throws -> JSONValue {
        guard let fields = value.objectValue else {
            throw EnvelopeError("response is not a JSON object: \(value.description.prefix(200))")
        }
        // 官方信封：只认 type 明写的那两种，且必须带 result。
        if let type = fields["type"]?.stringValue {
            guard type == "server-response" || type == "client-response" else {
                throw EnvelopeError("unexpected envelope type \"\(type)\"")
            }
            guard let result = fields["result"] else {
                throw EnvelopeError("envelope \"\(type)\" has no result")
            }
            return try unwrapResult(result)
        }
        // 裸 result 本体。
        if fields["ok"] != nil {
            return try unwrapResult(value)
        }
        throw EnvelopeError("response is neither a server-response envelope nor an { ok, … } result")
    }

    private static func unwrapResult(_ result: JSONValue) throws -> JSONValue {
        guard let fields = result.objectValue, let ok = fields["ok"]?.boolValue else {
            throw EnvelopeError("result is not { ok:Bool, … }")
        }
        guard ok else {
            throw RPCFault.decode(fields["error"] ?? .null)
        }
        // void 业务结果序列化后确实没有 `value`（上游注释：a void business
        // result serializes with no `value` field at all）→ 空对象是对的。
        // 但**只有**这一种缺失是合法的：带数据的方法自己的二次解码仍会失败。
        return fields["value"] ?? .object([:])
    }
}
