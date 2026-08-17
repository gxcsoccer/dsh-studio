import Foundation
import DSHKit

/// 为什么失联。
public enum DisconnectReason: Hashable, Sendable, CustomStringConvertible {
    /// `bridge.json` 不在 —— runtime 没起，或者没装 studio profile。
    case runtimeNotRunning(String)
    /// token 缺失 / 被拒（401 / 403）。
    case unauthorized
    /// descriptor 本身不安全（非 loopback、权限太松）。
    case insecureDescriptor(String)
    case transport(String)
    case streamEnded
    case cancelled

    public var description: String {
        switch self {
        case .runtimeNotRunning(let detail): "runtime not running: \(detail)"
        case .unauthorized: "unauthorized"
        case .insecureDescriptor(let detail): "insecure descriptor: \(detail)"
        case .transport(let detail): "transport failure: \(detail)"
        case .streamEnded: "event stream ended"
        case .cancelled: "cancelled"
        }
    }

    /// 换 token / 修权限之前重试没有意义。
    public var isRetryable: Bool {
        switch self {
        case .unauthorized, .insecureDescriptor: false
        case .runtimeNotRunning, .transport, .streamEnded, .cancelled: true
        }
    }
}

/// 与 runtime 的连接状态。
///
/// bridge-contract.md §2.3：「宿主必须能显示『与 runtime 失联』态。这是从
/// `codex/agent-sidebar` 分支继承的教训：断连横幅是第一个值得原生化的东西，
/// 因为 Web UI 断连时恰好也没法告诉你它断连了。」
///
/// 所以这个类型是 W1 的一等公民，不是一个 Bool。
public enum RuntimeLinkState: Hashable, Sendable {
    case idle
    case connecting
    /// 已连上并在消费事件流。
    case live(since: Date)
    /// 断得太久，正在放弃增量、重拉全量快照。
    case resyncing
    case disconnected(reason: DisconnectReason, since: Date)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// 断连横幅文案（nil = 不显示横幅）。
    public var bannerText: String? {
        switch self {
        case .idle, .live:
            return nil
        case .connecting:
            return "正在连接 dsh runtime…"
        case .resyncing:
            return "已重新连上，正在重新同步会话快照…"
        case .disconnected(let reason, _):
            switch reason {
            case .runtimeNotRunning:
                return "与 dsh runtime 失联：runtime 未运行"
            case .unauthorized:
                return "与 dsh runtime 失联：桥接 token 无效，请重启 dsh"
            case .insecureDescriptor(let detail):
                return "拒绝连接：\(detail)"
            case .transport(let detail):
                return "与 dsh runtime 失联：\(detail)"
            case .streamEnded:
                return "与 dsh runtime 失联：事件流已结束"
            case .cancelled:
                return nil
            }
        }
    }
}

/// 断线续传决策（bridge-contract.md §2.3）。
public enum ResumePlan: Hashable, Sendable {
    /// 带 `Last-Event-ID` 续传。
    case resume(lastEventID: String)
    /// 放弃增量：重拉全量快照再续流。
    case fullResync
}

/// 续传策略。
public struct ResumePolicy: Hashable, Sendable {
    /// runtime 侧的事件保留窗口。超过它就没有增量可续了。
    public var retentionWindow: TimeInterval
    /// 重连退避的上下限。
    public var minimumBackoff: TimeInterval
    public var maximumBackoff: TimeInterval

    public init(
        retentionWindow: TimeInterval = 120,
        minimumBackoff: TimeInterval = 0.5,
        maximumBackoff: TimeInterval = 10
    ) {
        self.retentionWindow = retentionWindow
        self.minimumBackoff = minimumBackoff
        self.maximumBackoff = maximumBackoff
    }

    /// 纯函数：给定「上次游标」与「断开了多久」，决定续传还是重拉。
    public func plan(lastEventID: String?, disconnectedFor gap: TimeInterval) -> ResumePlan {
        guard let lastEventID, !lastEventID.isEmpty else { return .fullResync }
        guard gap <= retentionWindow else { return .fullResync }
        return .resume(lastEventID: lastEventID)
    }

    public func backoff(attempt: Int) -> TimeInterval {
        let raw = minimumBackoff * pow(2, Double(max(0, attempt - 1)))
        return min(maximumBackoff, raw)
    }
}
