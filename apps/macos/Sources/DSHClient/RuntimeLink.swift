import Foundation
import DSHKit

/// 为什么失联 —— **分类本身就是可诊断性**。
///
/// 这不是一个 `unknown` 加一段字符串：把「文件不在」「端口没人应答」「token
/// 被拒」「读不懂对端的回答」「超时」压成同一个原因，等于把排查成本从代码
/// 转移到用户。每个 case 都对应一个**不同的下一步**（见 `remedy`），这才是
/// 分类的判据 —— 如果两个原因的下一步一样，它们本该是同一个 case。
public enum DisconnectReason: Hashable, Sendable, CustomStringConvertible {
    /// `bridge.json` 不在 —— runtime 没起，或者没装 studio profile。
    case runtimeNotRunning(String)
    /// 握手文件在，但那个端口上没人应答：surface 进程死了 / 正在重启，
    /// 或者文件是上一次运行留下的（`pid` 字段就是为这个诊断存在的）。
    ///
    /// 与 `runtimeNotRunning` 分开是有代价换来的：两者的下一步不同 ——
    /// 前者是「把 runtime 起起来」，后者是「它刚刚还活着，现在没了」。
    case surfaceUnreachable(String)
    /// token 缺失 / 被拒（401 / 403）。token 是一次性的，重启 dsh 会换一把。
    case unauthorized
    /// descriptor 本身不安全（非 loopback、权限太松）。
    case insecureDescriptor(String)
    /// 请求超时。端口有人接，但不回答 —— 与「没人接」是两种故障。
    case timedOut(String)
    /// 对端回答了，但我们读不懂：JSON 解不开、字段与契约不符、`ok:false`
    /// 之外的形状。**这一条最容易被静默吞掉**（旧实现用 `try?` 兜成空表，
    /// 于是上游漂移长得和「你没有会话」一模一样），所以它必须是一个显式原因。
    case protocolBroken(String)
    /// 其余传输失败（含 HTTP 5xx）。
    case transport(String)
    case streamEnded
    case cancelled

    /// 稳定的机器可读代码。日志与测试都用它断言分类，不去 grep 中文文案。
    public var code: String {
        switch self {
        case .runtimeNotRunning: "runtime-not-running"
        case .surfaceUnreachable: "surface-unreachable"
        case .unauthorized: "unauthorized"
        case .insecureDescriptor: "insecure-descriptor"
        case .timedOut: "timed-out"
        case .protocolBroken: "protocol-broken"
        case .transport: "transport"
        case .streamEnded: "stream-ended"
        case .cancelled: "cancelled"
        }
    }

    public var description: String {
        switch self {
        case .runtimeNotRunning(let detail): "runtime not running: \(detail)"
        case .surfaceUnreachable(let detail): "data channel unreachable: \(detail)"
        case .unauthorized: "unauthorized"
        case .insecureDescriptor(let detail): "insecure descriptor: \(detail)"
        case .timedOut(let detail): "timed out: \(detail)"
        case .protocolBroken(let detail): "protocol failure: \(detail)"
        case .transport(let detail): "transport failure: \(detail)"
        case .streamEnded: "event stream ended"
        case .cancelled: "cancelled"
        }
    }

    /// 换 token / 修权限之前重试没有意义。
    ///
    /// `protocolBroken` **算**可重试：读不懂的最常见成因是 runtime 正在被换成
    /// 另一个版本，而不是我们永久性地读错了。区别在于文案会说清是「读不懂」
    /// 而不是「连不上」。
    public var isRetryable: Bool {
        switch self {
        case .unauthorized, .insecureDescriptor: false
        case .runtimeNotRunning, .surfaceUnreachable, .timedOut,
             .protocolBroken, .transport, .streamEnded, .cancelled: true
        }
    }

    /// 一行人话，画在侧栏/横幅上。
    ///
    /// 每一条都必须让人看出这是**连接问题**，不是「你没有会话」—— 这正是本轮
    /// 修的那个 bug（空态与失败态长得一模一样）。
    public var headline: String? {
        switch self {
        case .runtimeNotRunning: "连不上 dsh runtime"
        case .surfaceUnreachable: "与 dsh runtime 的数据通道中断"
        case .unauthorized: "桥接 token 已失效"
        case .insecureDescriptor: "拒绝连接 dsh runtime"
        case .timedOut: "dsh runtime 没有在超时内回答"
        case .protocolBroken: "读不懂 dsh runtime 的回答"
        case .transport: "与 dsh runtime 的数据通道出错"
        case .streamEnded: "dsh runtime 的事件流已结束"
        case .cancelled: nil
        }
    }

    /// 下一步。分类存在的意义就在这一栏 —— 两个原因的 `remedy` 相同即应合并。
    ///
    /// ⚠️ 这一栏是**给人读的**，所以刻意不转发 `URLError.localizedDescription`：
    /// 那东西在合成的错误上会长成「The operation couldn't be completed.
    /// (NSURLErrorDomain error -1004.)」，把一句人话变回一行栈迹。原始细节留在
    /// `description` 里（日志读它），人话留在这里。
    /// 例外是**稳定且真正有用**的细节：`bridge.json` 的路径、`HTTP 503`、
    /// 解码不上的那个方法名 —— 它们本身就是下一步要看的东西。
    public var remedy: String? {
        switch self {
        case .runtimeNotRunning(let path):
            "没有找到 \(path)：先启动 `dsh --profile studio`"
        case .surfaceUnreachable:
            "那个端口上已经没有人应答 —— runtime 可能已退出或正在重启"
        case .unauthorized:
            "token 是一次性的：重启 dsh 会换一把新的，然后点重试"
        case .insecureDescriptor(let detail):
            detail
        case .timedOut:
            "runtime 还在，但没有按时回答 —— 它可能正忙或卡住了"
        case .protocolBroken(let detail):
            "对端回答的形状与契约不符（\(detail)）—— 很可能 runtime 与本 app 版本不一致"
        case .transport(let detail):
            detail
        case .streamEnded:
            "正在自动重连"
        case .cancelled:
            nil
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
///
/// ## 与控制通道心跳（`ControlLinkHealth`）的分工
///
/// 两条通道各有一套健康度，**语义刻意不同**，因为失联后的动作不同：
///
/// | | 控制通道 `ControlLinkHealth` | 数据通道 `RuntimeLinkState` |
/// | --- | --- | --- |
/// | 判死动作 | 撤下所有原生视图，官方 Web UI 接管（ADR-0004） | 原生视图**留在屏幕上**，但必须显式说「数据不可信」 |
/// | 判死后 | 不自动复活（避免界面在两种实现间抖动） | **自动重连**（退避），领域数据回来就继续画 |
///
/// 之所以不能反过来：控制通道死了，原生视图连 props 与几何都拿不到，留着就是
/// 一块骗人的界面；数据通道死了，编排还活着，此时退回 Web UI 反而更糟 ——
/// 官方 UI 用的是同一个 runtime，它也一样没有数据，只是不会告诉你。
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

    /// 机器可读标签，给日志用（中文横幅文案会改，这个键不改）。
    public var label: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case .live: "live"
        case .resyncing: "resyncing"
        case .disconnected(let reason, _): "disconnected(\(reason.code))"
        }
    }

    /// 失败原因（非失败态为 nil）。
    public var failureReason: DisconnectReason? {
        guard case .disconnected(let reason, _) = self else { return nil }
        return reason
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
            guard let headline = reason.headline else { return nil }
            guard let remedy = reason.remedy else { return headline }
            return "\(headline)：\(remedy)"
        }
    }
}

/// 数据通道当前**能不能支撑一个列表读模型** —— 视图三态的唯一判据。
///
/// 为什么这个判断住在数据通道这一侧，而不是视图里：原生侧栏最初只区分
/// 「没会话」与「搜索无匹配」，于是「连不上 runtime」被渲染成了「暂无会话」
/// —— 一句**正确的话**用在了一个**错误的前提**上。把判据变成一个可单测的
/// 纯读模型，视图只做 `switch`，这个坑才不会在 W2 的下一个列表里重现。
public enum DataAvailability: Hashable, Sendable {
    /// 还在连（或在重同步），手上还没有可信快照。既不是空也不是失败。
    case pending
    /// 数据通道失败 —— **绝不允许渲染成空态**。
    case unavailable(reason: DisconnectReason, retryable: Bool)
    /// 快照可信，且确实没有可显示的会话。这是一句正确的「暂无会话」。
    case empty
    /// 有数据可画，而且链路正常 —— 屏幕上的东西就是现状。
    case populated
    /// 有数据可画，但链路**不在** live：这些行是最后一次成功读到的样子，
    /// 不保证是现在的样子。
    ///
    /// 为什么要和 `populated` 分开：把它们合成一个，等于让界面宣称
    /// 「这就是你现在的会话」，而事实是「这是若干秒/分钟前的会话，之后发生的
    /// 事我们一概不知道」。数据过期是一种失败，只是它的正确画法不是清空列表，
    /// 而是**保留旧行 + 明说它可能已过期**（G-13）。
    /// `reason == nil` 表示正在（重）连的过程中。
    case stale(reason: DisconnectReason?, retryable: Bool)

    /// 「连不上，而且手上没有能画的行」→ 列表必须画失败态。
    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// 屏幕上的内容是否**可以当成现状**来读。
    ///
    /// 只有 `populated` / `empty` 为真：这两态背后是一次成功的全量对齐 + 一条
    /// 活着的事件流。其余都要求界面把「你看到的可能不是现在」说出来。
    public var isCurrent: Bool {
        switch self {
        case .populated, .empty: true
        case .pending, .unavailable, .stale: false
        }
    }

    /// 稳定的机器可读标签，给日志用：真机验证要能回答「界面这一刻画的是哪一态」，
    /// 而不是靠人对着屏幕转述。中文文案会改，这个键不改。
    public var label: String {
        switch self {
        case .pending: "pending"
        case .empty: "empty"
        case .populated: "populated"
        case .unavailable(let reason, _): "unavailable(\(reason.code))"
        case .stale(let reason, _): "stale(\(reason?.code ?? "reconnecting"))"
        }
    }

    /// 手上还有行可画吗（`populated` / `stale`）。
    public var hasRows: Bool {
        switch self {
        case .populated, .stale: true
        case .pending, .empty, .unavailable: false
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
    /// 一次连接活多久才算「站稳了」，从而可以把退避计数归零。
    ///
    /// 没有这个窗口，退避就是假的：一个每次刚连上就断的 runtime 会让
    /// `attempt` 每轮都被重置成 0，于是我们以 `minimumBackoff` 的频率
    /// 永久狂打它 —— 退避代码看起来存在，实际从不生效。
    public var stabilityWindow: TimeInterval

    public init(
        retentionWindow: TimeInterval = 120,
        minimumBackoff: TimeInterval = 0.5,
        maximumBackoff: TimeInterval = 10,
        stabilityWindow: TimeInterval = 5
    ) {
        self.retentionWindow = retentionWindow
        self.minimumBackoff = minimumBackoff
        self.maximumBackoff = maximumBackoff
        self.stabilityWindow = stabilityWindow
    }

    /// 纯函数：给定「上次游标」与「断开了多久」，决定续传还是重拉。
    public func plan(lastEventID: String?, disconnectedFor gap: TimeInterval) -> ResumePlan {
        guard let lastEventID, !lastEventID.isEmpty else { return .fullResync }
        guard gap <= retentionWindow else { return .fullResync }
        return .resume(lastEventID: lastEventID)
    }

    /// 指数退避，`maximumBackoff` 封顶：**有节制**的重试 —— 无限的耐心，
    /// 有上限的频率。永不放弃是刻意的（用户先开 app 再开 runtime 是最常见的
    /// 顺序），所以约束加在「多久打一次」而不是「打几次就不打了」。
    public func backoff(attempt: Int) -> TimeInterval {
        let raw = minimumBackoff * pow(2, Double(max(0, attempt - 1)))
        return min(maximumBackoff, raw)
    }
}
