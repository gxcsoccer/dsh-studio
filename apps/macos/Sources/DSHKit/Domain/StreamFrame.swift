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
/// SSE 的 `event:` 名 → 帧类型：
///   - `session`    → `session/event` 透传（bridge-contract.md §2.2 明写的那一种）
///   - `host`       → 宿主级增量（会话增删、running 翻转、工作区变更）
///   - `projection` → 投影变更（会话标题）
///
/// ⚠️ 契约缺口：bridge-contract.md §2.2 只写了 `event: session` 一种。
/// W1 的侧栏必须知道工作区变更和会话标题，这两样在 `session/event` 里没有，
/// 所以这里扩了两个 event 名，并在 `.unknown` 上兜底：未知 event 名不丢弃、
/// 不崩，交给遥测记账。详见交付报告的「设计漏洞」一节。
public enum StreamFrame: Hashable, Sendable {
    case session(SessionFrame)
    case host(HostFrame)
    case projection(ProjectionFrame)
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
        case let other:
            return .unknown(name: other, data: data)
        }
    }
}
