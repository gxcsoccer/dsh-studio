import Foundation

/// 最小 JSON 值模型。
///
/// 存在理由（bridge-contract.md §3）：所有 tagged union 都必须带
/// `case unknown(JSONValue)` 兜底，于是需要一个能原样保存任意上游
/// 载荷的类型 —— 上游加变体时我们降级显示，而不是崩溃。
///
/// 刻意不引入 `Any`：`JSONValue` 是 `Sendable` + `Hashable`，可以安全跨
/// actor 传递、可以进 `@Observable` 状态、可以直接参与断言。
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // 顺序重要：Bool 必须在 Number 之前（JSON `true` 不是数字），
        // Number 必须在 String 之前（避免把 "1" 读成 1）。
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // 整数原样往回写，避免 seq/priority 这类字段变成 "1.0"。
            if let exact = JSONValue.exactInt(value) {
                try container.encode(exact)
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    private static func exactInt(_ value: Double) -> Int? {
        guard value.isFinite, value.rounded() == value,
              value >= -9_007_199_254_740_992, value <= 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }
}

// MARK: - 读取便利

extension JSONValue {
    public var isNull: Bool { self == .null }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite,
              value.rounded() == value else { return nil }
        return Int(value)
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// 结构深度，用于给来自 WebView 的不可信输入设上限（bridge-contract.md §5）。
    public var depth: Int {
        switch self {
        case .null, .bool, .number, .string:
            return 1
        case .array(let items):
            return 1 + (items.map(\.depth).max() ?? 0)
        case .object(let fields):
            return 1 + (fields.values.map(\.depth).max() ?? 0)
        }
    }
}

// MARK: - 序列化

extension JSONValue {
    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func decode(json text: String) throws -> JSONValue {
        try decode(Data(text.utf8))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func jsonText() throws -> String {
        String(decoding: try encoded(), as: UTF8.self)
    }

    /// 把任意 `Encodable` 转成 `JSONValue`，用于把强类型载荷塞进信封。
    public init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONValue.decode(data)
    }

    /// 把 `JSONValue` 解成强类型载荷。
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: try encoded())
    }
}

// MARK: - 字面量（测试与构造载荷时的可读性）

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String {
        (try? jsonText()) ?? "<invalid json>"
    }
}
