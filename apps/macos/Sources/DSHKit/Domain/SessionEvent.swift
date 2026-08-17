import Foundation

/// 一条 `session/event`（上游 `SessionEvent`：严格信封 + 宽 data）。
///
/// 会话状态**以 `session/event` 日志为准**（bridge-contract.md §2.2，
/// 官方原则 *Model-visible means logged*）。原生端只做投影缓存。
public struct SessionEventRecord: Hashable, Sendable, Codable {
    public var type: String
    public var seq: Int
    public var time: Double
    public var data: JSONValue
    public var ignorable: Bool?

    public init(type: String, seq: Int, time: Double, data: JSONValue = .null, ignorable: Bool? = nil) {
        self.type = type
        self.seq = seq
        self.time = time
        self.data = data
        self.ignorable = ignorable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        seq = try container.decode(Int.self, forKey: .seq)
        time = try container.decodeIfPresent(Double.self, forKey: .time) ?? 0
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data) ?? .null
        ignorable = try container.decodeIfPresent(Bool.self, forKey: .ignorable)
    }

    /// 事件的 tagged union 视图。
    public var payload: SessionEventPayload {
        SessionEventPayload(type: type, data: data)
    }
}

/// `session/event` 的已知变体 + 兜底。
///
/// bridge-contract.md §3：**所有 tagged union 必须带 `case unknown(JSONValue)`**。
/// 上游的 `ChatNodeKind` / 事件类型都是 declaration merging 出来的开放集合
/// （slot-map.md §7.2：官方自己就有 `unknown` 兜底渲染器），所以穷举 switch
/// 是必然会崩的写法。
public enum SessionEventPayload: Hashable, Sendable {
    case userMessage(text: String?)
    case assistantMessage(text: String?)
    case assistantChunk(delta: String?)
    case turnStart
    case turnEnd
    case toolCall(name: String?, callID: String?)
    case toolResult(callID: String?, ok: Bool?)
    /// 兜底：原样保留 `{ type, data }`，降级显示而不是崩溃。
    case unknown(JSONValue)

    public init(type: String, data: JSONValue) {
        switch type {
        case "user/message":
            self = .userMessage(text: SessionEventPayload.text(in: data))
        case "assistant/message":
            self = .assistantMessage(text: SessionEventPayload.text(in: data))
        case "assistant/chunk":
            self = .assistantChunk(delta: data["delta"]?.stringValue ?? SessionEventPayload.text(in: data))
        case "turn/start":
            self = .turnStart
        case "turn/end":
            self = .turnEnd
        case "tool/call":
            self = .toolCall(name: data["name"]?.stringValue, callID: data["callId"]?.stringValue)
        case "tool/result":
            self = .toolResult(callID: data["callId"]?.stringValue, ok: data["ok"]?.boolValue)
        default:
            self = .unknown(.object(["type": .string(type), "data": data]))
        }
    }

    /// 未知变体的原始 type（遥测/兜底卡片要显示它）。
    public var unknownType: String? {
        guard case .unknown(let value) = self else { return nil }
        return value["type"]?.stringValue
    }

    private static func text(in data: JSONValue) -> String? {
        if let direct = data["text"]?.stringValue { return direct }
        guard let parts = data["message"]?["content"]?.arrayValue else { return nil }
        let texts = parts.compactMap { $0["text"]?.stringValue }
        return texts.isEmpty ? nil : texts.joined()
    }
}
