import Foundation

/// 控制通道错误码 —— **封闭集合**（bridge-contract.md §1.5）。
///
/// 这里刻意**不给** `case unknown`：错误码是我们自己的产品表面（桥不是
/// DeepSeek 的公共 API），封闭是有意的。收到集合外的码 = 对端不是我们
/// 认识的 client 半 → 按 `bad_payload` 拒绝，不猜。
///
/// 对比：领域模型（session event、host frame）走上游契约，必须带
/// `case unknown(JSONValue)`，见 `SessionEventPayload` / `HostFrame`。
public enum BridgeErrorCode: String, Sendable, Hashable, CaseIterable {
    case unknownMethod = "unknown_method"
    case badPayload = "bad_payload"
    case protocolMismatch = "protocol_mismatch"
    case slotNotDeclared = "slot_not_declared"
    case slotNotMounted = "slot_not_mounted"
    case priorityConflict = "priority_conflict"
    case internalError = "internal"

    /// `priority_conflict` 必须大声失败：它意味着有别人占了我们的 priority，
    /// 需要人来决策，不能自动挪位（bridge-contract.md §1.5）。
    public var demandsHumanDecision: Bool {
        self == .priorityConflict || self == .slotNotDeclared
    }
}

/// 信封里的 `e`：`{ code, message, retryable }`。
public struct BridgeFault: Error, Hashable, Sendable, CustomStringConvertible {
    public let code: BridgeErrorCode
    public let message: String
    public let retryable: Bool

    public init(code: BridgeErrorCode, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var description: String {
        "\(code.rawValue): \(message)\(retryable ? " (retryable)" : "")"
    }

    public static func decode(_ value: JSONValue) throws -> BridgeFault {
        guard let fields = value.objectValue else {
            throw BridgeDecodingError.malformedEnvelope("`e` is not an object")
        }
        guard let rawCode = fields["code"]?.stringValue else {
            throw BridgeDecodingError.malformedEnvelope("`e.code` missing")
        }
        guard let code = BridgeErrorCode(rawValue: rawCode) else {
            throw BridgeDecodingError.unknownErrorCode(rawCode)
        }
        let message = fields["message"]?.stringValue ?? ""
        return BridgeFault(
            code: code,
            // 不可信输入：截断消息，避免日志被灌爆。
            message: String(message.prefix(4096)),
            retryable: fields["retryable"]?.boolValue ?? false
        )
    }

    public func encoded() -> JSONValue {
        .object([
            "code": .string(code.rawValue),
            "message": .string(message),
            "retryable": .bool(retryable),
        ])
    }
}
