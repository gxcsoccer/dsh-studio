import Foundation

/// 控制通道协议版本（bridge-contract.md §1.2 / §4）。
///
/// `v` 只在**不兼容**变更时递增。收到未知 `v` → 拒绝并降级到纯 Web，不猜。
public enum BridgeProtocol {
    public static let current = 1
}

/// `req` / `res` 的 ULID。
///
/// bridge-contract.md §1.2：`id` 是 ULID，单调递增便于排序调试。
public struct MessageID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    /// 合法性校验：来自 WebView 的 `id` 是不可信输入（§5）。
    /// ULID = 26 个 Crockford base32 字符。
    public var isWellFormed: Bool {
        rawValue.count == 26 && rawValue.allSatisfy { ULID.alphabet.contains($0) }
    }
}

/// 最小 ULID 生成器：48bit 毫秒时间戳 + 80bit 随机，同毫秒内单调递增。
public enum ULID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static let state = Mutex(State(lastMillis: 0, lastRandom: [UInt8](repeating: 0, count: 10)))

    private struct State {
        var lastMillis: UInt64
        var lastRandom: [UInt8]
    }

    public static func generate(now: Date = Date()) -> MessageID {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let random: [UInt8] = state.withLock { current in
            if millis == current.lastMillis {
                // 同毫秒：随机部分 +1，保持单调。
                var bytes = current.lastRandom
                var index = bytes.count - 1
                while index >= 0 {
                    if bytes[index] == 0xFF {
                        bytes[index] = 0
                        index -= 1
                    } else {
                        bytes[index] += 1
                        break
                    }
                }
                current.lastRandom = bytes
                return bytes
            }
            var bytes = [UInt8](repeating: 0, count: 10)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            current.lastMillis = millis
            current.lastRandom = bytes
            return bytes
        }

        var bits: [UInt8] = []
        bits.reserveCapacity(16)
        for shift in stride(from: 40, through: 0, by: -8) {
            bits.append(UInt8((millis >> UInt64(shift)) & 0xFF))
        }
        bits.append(contentsOf: random)
        return MessageID(rawValue: encodeBase32(bits))
    }

    private static func encodeBase32(_ bytes: [UInt8]) -> String {
        // 128 bit → 26 字符（26 * 5 = 130 bit）：前置 2 个 0 bit 补齐。
        //
        // 这里**必须**从高位补零、而不是尾部截断：尾部截断会把随机部分的最低
        // 位丢掉，于是同毫秒内 +1 的单调计数器会编码出完全相同的字符串
        // （踩过一次，由 `ULID 是 26 位 Crockford base32 且单调` 守着）。
        var output = ""
        output.reserveCapacity(26)
        var accumulator: UInt = 0
        var bitCount = 2
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt(byte)
            bitCount += 8
            while bitCount >= 5 {
                let index = Int((accumulator >> UInt(bitCount - 5)) & 0x1F)
                output.append(alphabet[index])
                bitCount -= 5
            }
        }
        return output
    }
}

/// 极简互斥锁（避免为了一个 ULID 计数器引入并发依赖）。
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// 信封的四态（任务书用语：req/res/evt/err）。
///
/// 线上编码遵守 bridge-contract.md §1.2 的三个 `t` 值：`err` 不是独立的 `t`，
/// 而是 `t:"res"` + `ok:false`。Swift 侧把它建模成第四个 case，是为了让
/// 「失败回执」在类型上无法被忽略 —— 编译器会强制处理它。
public enum BridgeMessageKind: String, Sendable, Hashable {
    case req
    case res
    case err
    case evt
}

/// 控制通道信封（bridge-contract.md §1.2）：`v` / `t` / `id` / `m` / `p` / `e`。
public enum BridgeEnvelope: Sendable, Hashable {
    /// `{ v, t:"req", id, m, p }`
    case request(id: MessageID, method: String, payload: JSONValue)
    /// `{ v, t:"res", id, ok:true, p }`
    case success(id: MessageID, payload: JSONValue)
    /// `{ v, t:"res", id, ok:false, e }`
    case failure(id: MessageID, error: BridgeFault)
    /// `{ v, t:"evt", m, p }`
    case event(method: String, payload: JSONValue)

    public var kind: BridgeMessageKind {
        switch self {
        case .request: .req
        case .success: .res
        case .failure: .err
        case .event: .evt
        }
    }

    public var id: MessageID? {
        switch self {
        case .request(let id, _, _), .success(let id, _), .failure(let id, _): id
        case .event: nil
        }
    }

    public var method: String? {
        switch self {
        case .request(_, let method, _), .event(let method, _): method
        case .success, .failure: nil
        }
    }

    public var payload: JSONValue {
        switch self {
        case .request(_, _, let payload), .success(_, let payload), .event(_, let payload): payload
        case .failure: .null
        }
    }
}

/// 信封解码失败的原因。全部是「拒绝」，没有一个是「猜」。
public enum BridgeDecodingError: Error, Hashable, Sendable, CustomStringConvertible {
    /// 未知协议版本 → 降级纯 Web（§1.2 / §4）。
    case unsupportedProtocolVersion(Int)
    /// `v` 不是整数，或者干脆没有。
    case malformedProtocolVersion
    /// 未知 `t`。
    case unknownMessageKind(String)
    /// 结构性缺字段 / 字段类型不对。
    case malformedEnvelope(String)
    /// 未知错误码 —— 错误码是封闭集合（§1.5），不允许扩展。
    case unknownErrorCode(String)
    /// 载荷不是合法 JSON。
    case notJSON

    public var description: String {
        switch self {
        case .unsupportedProtocolVersion(let version):
            "unsupported bridge protocol version \(version) (host speaks \(BridgeProtocol.current))"
        case .malformedProtocolVersion:
            "envelope has no integer `v`"
        case .unknownMessageKind(let kind):
            "unknown envelope kind `\(kind)`"
        case .malformedEnvelope(let detail):
            "malformed envelope: \(detail)"
        case .unknownErrorCode(let code):
            "unknown bridge error code `\(code)`"
        case .notJSON:
            "message body is not JSON"
        }
    }
}

extension BridgeEnvelope {
    private enum Key: String {
        case v, t, id, m, p, e, ok
    }

    /// 从已解析的 JSON 解码信封。
    ///
    /// 这是控制通道**唯一**的入口校验点：来自 WebView 的消息一律当不可信
    /// 输入（bridge-contract.md §5）。任何不合契约的东西在这里被拒绝，
    /// 不进入 `NativeSlotHost`。
    public static func decode(_ value: JSONValue) throws -> BridgeEnvelope {
        guard let fields = value.objectValue else {
            throw BridgeDecodingError.malformedEnvelope("top level is not an object")
        }
        guard let versionValue = fields[Key.v.rawValue] else {
            throw BridgeDecodingError.malformedProtocolVersion
        }
        guard let version = versionValue.intValue else {
            throw BridgeDecodingError.malformedProtocolVersion
        }
        guard version == BridgeProtocol.current else {
            throw BridgeDecodingError.unsupportedProtocolVersion(version)
        }
        guard let kind = fields[Key.t.rawValue]?.stringValue else {
            throw BridgeDecodingError.malformedEnvelope("missing `t`")
        }
        let payload = fields[Key.p.rawValue] ?? .object([:])

        switch kind {
        case BridgeMessageKind.req.rawValue:
            let id = try requireID(fields)
            guard let method = fields[Key.m.rawValue]?.stringValue, !method.isEmpty else {
                throw BridgeDecodingError.malformedEnvelope("req without `m`")
            }
            return .request(id: id, method: method, payload: payload)

        case BridgeMessageKind.res.rawValue:
            let id = try requireID(fields)
            guard let ok = fields[Key.ok.rawValue]?.boolValue else {
                throw BridgeDecodingError.malformedEnvelope("res without boolean `ok`")
            }
            if ok {
                return .success(id: id, payload: payload)
            }
            guard let errorValue = fields[Key.e.rawValue] else {
                throw BridgeDecodingError.malformedEnvelope("res ok:false without `e`")
            }
            return .failure(id: id, error: try BridgeFault.decode(errorValue))

        case BridgeMessageKind.evt.rawValue:
            guard let method = fields[Key.m.rawValue]?.stringValue, !method.isEmpty else {
                throw BridgeDecodingError.malformedEnvelope("evt without `m`")
            }
            return .event(method: method, payload: payload)

        default:
            throw BridgeDecodingError.unknownMessageKind(kind)
        }
    }

    private static func requireID(_ fields: [String: JSONValue]) throws -> MessageID {
        guard let raw = fields[Key.id.rawValue]?.stringValue, !raw.isEmpty else {
            throw BridgeDecodingError.malformedEnvelope("missing `id`")
        }
        // 长度上限：不可信输入不许用一个 1MB 的 id 把我们的表撑爆。
        guard raw.count <= 64 else {
            throw BridgeDecodingError.malformedEnvelope("`id` too long")
        }
        return MessageID(rawValue: raw)
    }

    public static func decode(json text: String) throws -> BridgeEnvelope {
        guard let value = try? JSONValue.decode(json: text) else {
            throw BridgeDecodingError.notJSON
        }
        return try decode(value)
    }

    /// 编码成线上形态。
    public func encoded() -> JSONValue {
        var fields: [String: JSONValue] = [Key.v.rawValue: .number(Double(BridgeProtocol.current))]
        switch self {
        case .request(let id, let method, let payload):
            fields[Key.t.rawValue] = .string(BridgeMessageKind.req.rawValue)
            fields[Key.id.rawValue] = .string(id.rawValue)
            fields[Key.m.rawValue] = .string(method)
            fields[Key.p.rawValue] = payload
        case .success(let id, let payload):
            fields[Key.t.rawValue] = .string(BridgeMessageKind.res.rawValue)
            fields[Key.id.rawValue] = .string(id.rawValue)
            fields[Key.ok.rawValue] = .bool(true)
            fields[Key.p.rawValue] = payload
        case .failure(let id, let fault):
            fields[Key.t.rawValue] = .string(BridgeMessageKind.res.rawValue)
            fields[Key.id.rawValue] = .string(id.rawValue)
            fields[Key.ok.rawValue] = .bool(false)
            fields[Key.e.rawValue] = fault.encoded()
        case .event(let method, let payload):
            fields[Key.t.rawValue] = .string(BridgeMessageKind.evt.rawValue)
            fields[Key.m.rawValue] = .string(method)
            fields[Key.p.rawValue] = payload
        }
        return .object(fields)
    }

    public func jsonText() throws -> String {
        try encoded().jsonText()
    }
}
