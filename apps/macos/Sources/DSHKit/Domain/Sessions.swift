import Foundation

/// 会话来源（上游 `SessionSummary.origin`）。
///
/// 上游只声明了 `'subagent'`，但它是 tagged union 的一员 → 按
/// bridge-contract.md §3 带 `unknown` 兜底。
public enum SessionOrigin: Hashable, Sendable, Codable {
    case subagent
    case unknown(JSONValue)

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        if value.stringValue == "subagent" {
            self = .subagent
        } else {
            self = .unknown(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .subagent: try JSONValue.string("subagent").encode(to: encoder)
        case .unknown(let value): try value.encode(to: encoder)
        }
    }
}

/// 会话投影快照（上游 `SessionProjectionsBlock`）。
///
/// `values` 刻意保持为 `[String: JSONValue]`：投影表 `SessionProjectionMap`
/// 是上游用 declaration merging 开放扩展的，任何插件都能加 key。穷举 = 早晚崩。
public struct SessionProjections: Hashable, Sendable, Codable {
    /// values 反映到的最后一个事件 seq；空日志为 -1。
    public var asOfSeq: Int
    public var values: [String: JSONValue]

    public init(asOfSeq: Int, values: [String: JSONValue]) {
        self.asOfSeq = asOfSeq
        self.values = values
    }

    /// 侧栏用的会话标题：走通用投影通道（上游注释：
    /// "Session titles ride the generic projection pair"）。
    public var title: String? {
        values["title"]?.stringValue
    }
}

/// `session.list` 的一行（上游 `SessionSummary`）。
public struct SessionSummary: Hashable, Sendable, Codable, Identifiable {
    public var sessionId: SessionID
    public var updatedAt: Double
    public var running: Bool
    public var blank: Bool
    public var parentSessionId: SessionID?
    public var origin: SessionOrigin?
    public var cwd: String?
    public var agentPreset: String?
    public var projections: SessionProjections?

    public var id: SessionID { sessionId }

    public init(
        sessionId: SessionID,
        updatedAt: Double,
        running: Bool,
        blank: Bool,
        parentSessionId: SessionID? = nil,
        origin: SessionOrigin? = nil,
        cwd: String? = nil,
        agentPreset: String? = nil,
        projections: SessionProjections? = nil
    ) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.running = running
        self.blank = blank
        self.parentSessionId = parentSessionId
        self.origin = origin
        self.cwd = cwd
        self.agentPreset = agentPreset
        self.projections = projections
    }

    /// 侧栏那一列灰色的相对时间（上游 `.time`）。
    ///
    /// 分档与文案抄自上游 `ui-workspace/src/client/tree.ts` 的 `relativeTime()`
    /// 与 `locales.ts` 的 `time.*`：`刚刚 / n分钟 / n小时 / n天 / n个月 / n年`。
    /// 自己另发明一套（例如 macOS 的 `RelativeDateTimeFormatter`，会说「3 分钟前」）
    /// 就是在同一条侧栏里放两种时间写法 —— 用户看得出来。
    ///
    /// **单位是毫秒**：上游 `Rows.tsx` 把 `row.updatedAt` 直接和 `Date.now()` 相减。
    /// 但这一位是从 runtime JSON 原样带过来的数字，写错单位的症状是「所有会话都
    /// 显示 56 年」，所以这里带一条**显式**的兜底：小于 `1e11` 的值只可能是秒
    /// （1e11 毫秒 = 1973 年，1e11 秒 = 5138 年），按秒解释。
    public func relativeUpdatedLabel(now: Date) -> String {
        let milliseconds = abs(updatedAt) < 1e11 ? updatedAt * 1000 : updatedAt
        let diff = max(0, now.timeIntervalSince1970 * 1000 - milliseconds)
        let minute = 60_000.0
        let hour = 3_600_000.0
        let day = 86_400_000.0
        switch diff {
        case ..<minute: return "刚刚"
        case ..<hour: return "\(Int(diff / minute))分钟"
        case ..<day: return "\(Int(diff / hour))小时"
        case ..<(30 * day): return "\(Int(diff / day))天"
        case ..<(365 * day): return "\(Int(diff / (30 * day)))个月"
        default: return "\(Int(diff / (365 * day)))年"
        }
    }

    /// 侧栏显示名：标题投影 → cwd 末段 → 短 id。
    public var displayTitle: String {
        if let title = projections?.title, !title.isEmpty { return title }
        if let cwd, let last = cwd.split(separator: "/").last, !last.isEmpty { return String(last) }
        return String(sessionId.rawValue.prefix(8))
    }
}

/// `workspace.list` 的一行（上游 `WorkspaceView`）。
public struct WorkspaceView: Hashable, Sendable, Codable, Identifiable {
    public var workspaceId: WorkspaceID
    public var path: String
    public var title: String
    public var sessionIds: [SessionID]
    public var createdAt: String
    public var updatedAt: String

    public var id: WorkspaceID { workspaceId }

    public init(
        workspaceId: WorkspaceID,
        path: String,
        title: String,
        sessionIds: [SessionID],
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.workspaceId = workspaceId
        self.path = path
        self.title = title
        self.sessionIds = sessionIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `session.list` 响应值。
public struct SessionListValue: Hashable, Sendable, Codable {
    public var items: [SessionSummary]

    public init(items: [SessionSummary]) { self.items = items }
}

/// `workspace.list` 响应值。
public struct WorkspaceListValue: Hashable, Sendable, Codable {
    public var items: [WorkspaceView]
    public var archivedSessionIds: [SessionID]

    public init(items: [WorkspaceView], archivedSessionIds: [SessionID] = []) {
        self.items = items
        self.archivedSessionIds = archivedSessionIds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([WorkspaceView].self, forKey: .items) ?? []
        archivedSessionIds = try container.decodeIfPresent([SessionID].self, forKey: .archivedSessionIds) ?? []
    }
}

/// `session.create` 响应值。
public struct SessionCreateValue: Hashable, Sendable, Codable {
    public var sessionId: SessionID
    public var agentPreset: String?

    public init(sessionId: SessionID, agentPreset: String? = nil) {
        self.sessionId = sessionId
        self.agentPreset = agentPreset
    }
}
