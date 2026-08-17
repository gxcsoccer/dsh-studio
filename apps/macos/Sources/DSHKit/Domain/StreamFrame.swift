import Foundation

/// SSE `event: session` 的 data（bridge-contract.md §2.2）：
/// `{ "sessionId":"…", "seq":128, "event":{ … } }`
public struct SessionFrame: Hashable, Sendable, Codable {
    public var sessionId: SessionID
    /// 流游标（= `Last-Event-ID`，bridge-contract.md §2.3）。
    public var seq: Int
    public var event: SessionEventRecord

    public init(sessionId: SessionID, seq: Int, event: SessionEventRecord) {
        self.sessionId = sessionId
        self.seq = seq
        self.event = event
    }
}

/// 宿主级增量（对齐上游 `HostFrame`）。
///
/// 全部带 `unknown` 兜底：上游是 developer preview，加一种 frame 不该让
/// 侧栏停止工作（ARCHITECTURE.md §7）。
public enum HostFrame: Hashable, Sendable {
    case sessionAdded(SessionSummary)
    case sessionRemoved(SessionID)
    case sessionStatus(SessionID, running: Bool)
    case agentError(SessionID, message: String)
    case workspaceChanged(WorkspaceView)
    case workspaceRemoved(WorkspaceID)
    case workspaceOrderChanged([WorkspaceID])
    case archivedSessionsChanged([SessionID])
    case unknown(JSONValue)

    public init(_ value: JSONValue) {
        guard let type = value["type"]?.stringValue else {
            self = .unknown(value)
            return
        }
        switch type {
        case "host/session-added":
            guard let id = value["sessionId"]?.stringValue else { self = .unknown(value); return }
            self = .sessionAdded(SessionSummary(
                sessionId: SessionID(id),
                updatedAt: value["updatedAt"]?.doubleValue ?? Date().timeIntervalSince1970,
                running: false,
                blank: value["blank"]?.boolValue ?? true,
                parentSessionId: value["parentSessionId"]?.stringValue.map { SessionID($0) },
                origin: value["origin"].flatMap { raw in
                    raw.isNull ? nil : (raw.stringValue == "subagent" ? .subagent : .unknown(raw))
                },
                cwd: value["cwd"]?.stringValue,
                agentPreset: value["agentPreset"]?.stringValue
            ))
        case "host/session-removed":
            guard let id = value["sessionId"]?.stringValue else { self = .unknown(value); return }
            self = .sessionRemoved(SessionID(id))
        case "host/session-status":
            guard let id = value["sessionId"]?.stringValue,
                  let running = value["running"]?.boolValue else { self = .unknown(value); return }
            self = .sessionStatus(SessionID(id), running: running)
        case "host/agent-error":
            guard let id = value["sessionId"]?.stringValue else { self = .unknown(value); return }
            self = .agentError(SessionID(id), message: value["message"]?.stringValue ?? "")
        case "host/workspace-changed":
            guard let raw = value["workspace"],
                  let workspace = try? raw.decoded(as: WorkspaceView.self) else { self = .unknown(value); return }
            self = .workspaceChanged(workspace)
        case "host/workspace-removed":
            guard let id = value["workspaceId"]?.stringValue else { self = .unknown(value); return }
            self = .workspaceRemoved(WorkspaceID(id))
        case "host/workspace-order-changed":
            guard let ids = value["workspaceIds"]?.arrayValue else { self = .unknown(value); return }
            self = .workspaceOrderChanged(ids.compactMap(\.stringValue).map { WorkspaceID($0) })
        case "host/archived-sessions-changed":
            guard let ids = value["archivedSessionIds"]?.arrayValue else { self = .unknown(value); return }
            self = .archivedSessionsChanged(ids.compactMap(\.stringValue).map { SessionID($0) })
        default:
            self = .unknown(value)
        }
    }

    /// 这一帧是否让「哪些会话该显示」的答案失效 → 需要重读 `session.list` /
    /// `workspace.list`（`nil` = 不需要）。
    ///
    /// 为什么连自己已经就地合并过的帧（session-added / workspace-changed）也要
    /// 重读：host 流给的是**片段**，而侧栏的行取决于两个只有全量才知道的事实
    /// —— 会话的 `blank`，以及它在哪个工作区的 `sessionIds` 里（G-13）。
    /// 真机抓流已确认：新建会话只发 `host/session-added`，工作区归属**不广播**。
    ///
    /// `.unknown` 也算失效：上游加了一种我们不认识的 host frame 时，正确反应是
    /// 「去重新读一遍」，而不是继续显示一份可能已经不对的列表。
    public var listInvalidationReason: String? {
        switch self {
        case .sessionAdded: "host/session-added"
        case .sessionRemoved: "host/session-removed"
        case .sessionStatus: "host/session-status"
        case .workspaceChanged: "host/workspace-changed"
        case .workspaceRemoved: "host/workspace-removed"
        case .workspaceOrderChanged: "host/workspace-order-changed"
        case .archivedSessionsChanged: "host/archived-sessions-changed"
        case .unknown(let value): "unmodelled \(value["type"]?.stringValue ?? "host/?")"
        // agent 错误只影响横幅文案，不改变列表成员。
        case .agentError: nil
        }
    }
}

/// 一条投影变更（上游 mux `session/projection`）。会话标题就走这里。
public struct ProjectionFrame: Hashable, Sendable {
    public var sessionId: SessionID
    public var key: String
    public var value: JSONValue
    /// 该投影单元发射时的 watermark；合并规则是 higher-seq-wins。
    public var seq: Int

    public init(sessionId: SessionID, key: String, value: JSONValue, seq: Int) {
        self.sessionId = sessionId
        self.key = key
        self.value = value
        self.seq = seq
    }

    public init?(_ value: JSONValue) {
        guard let id = value["sessionId"]?.stringValue,
              let key = value["key"]?.stringValue,
              let seq = value["seq"]?.intValue else { return nil }
        self.init(sessionId: SessionID(id), key: key, value: value["value"] ?? .null, seq: seq)
    }
}

/// 数据通道的一帧（SSE）。
///
/// SSE 的 `event:` 名 → 帧类型，取自 **bridge 实际发的东西**
/// （`bridge-server.ts` 的 `MUX_STREAM.name` / `HOST_STREAM.name` / replay-gap 分支）：
///   - `session`            → 上游 `session/event` 透传（§2.2 明写的那一种）
///   - `host`               → 宿主级增量（会话增删、running 翻转、工作区变更）
///   - `mux`                → 上游 mux 里**除** `session/event` 之外的一切，原样转发，
///                            按内层 `type` 再分派（`session/projection`、`stream/error`…）
///   - `studio/replay-gap`  → 「你要的 seq 出了保留窗口」，必须重新拉全量
///   - `projection`         → Studio 自己的别名（历史包袱，保留兼容）
///
/// ⚠️ 历史教训（known-gaps G-12）：`mux` 和 `studio/replay-gap` 曾经**双双**掉进
/// `.unknown` 被静默记账。后果不是崩溃，而是更坏的东西：
///   - `session/projection` 走 mux → 会话标题永远不随实时事件更新；
///   - `stream/error` 走 mux → 上游明说流炸了，我们当没听见；
///   - `studio/replay-gap` → bridge 明说「你漏了事件，去重新基线」，我们继续
///     停在 `.live` 显示**过期**数据。
/// 「不认识的 event 名不要崩」是对的，但它不能变成「对端说的话我一概不听」。
public enum StreamFrame: Hashable, Sendable {
    case session(SessionFrame)
    case host(HostFrame)
    case projection(ProjectionFrame)
    /// 上游流自己报错（mux `stream/error`）：必须当失败处理，不许静默。
    case streamError(RPCFault)
    /// 增量有洞，只能重新基线（bridge `studio/replay-gap`，§2.3）。
    case replayGap(requested: Int?, oldest: Int?)
    case unknown(name: String, data: JSONValue)

    public static func decode(eventName: String?, data: JSONValue) -> StreamFrame {
        switch eventName ?? "message" {
        case "session":
            if let frame = try? data.decoded(as: SessionFrame.self) {
                return .session(frame)
            }
            return .unknown(name: "session", data: data)
        case "host":
            return .host(HostFrame(data))
        case "projection":
            if let frame = ProjectionFrame(data) {
                return .projection(frame)
            }
            return .unknown(name: "projection", data: data)
        case "studio/replay-gap":
            return .replayGap(
                requested: data["requested"]?.intValue,
                oldest: data["oldest"]?.intValue
            )
        // bridge 把 mux 的非 session/event 帧原样转发，类型藏在 body 的 `type` 里
        // （上游 `muxFrameSchema` 的判别式）。
        case "mux":
            switch data["type"]?.stringValue {
            case "session/projection":
                if let frame = ProjectionFrame(data) {
                    return .projection(frame)
                }
                return .unknown(name: "mux:session/projection", data: data)
            case "session/event":
                // 正常路径下 bridge 会把它命名为 `session`；万一没有，也别丢。
                if let frame = try? data.decoded(as: SessionFrame.self) {
                    return .session(frame)
                }
                return .unknown(name: "mux:session/event", data: data)
            case "stream/error":
                return .streamError(RPCFault.decode(data["error"] ?? .null))
            case let other:
                // approval/*、question/*、session/queue… W1 侧栏不建模，记账即可。
                return .unknown(name: "mux:\(other ?? "?")", data: data)
            }
        case let other:
            return .unknown(name: other, data: data)
        }
    }
}
