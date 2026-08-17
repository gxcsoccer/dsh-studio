import Foundation
import DSHKit

/// 控制通道的**运行期**健康度（known-gaps.md G-3）。
///
/// 握手 watchdog 只覆盖启动期。运行期 client 半可能半静默死亡（JS 异常卡住
/// 事件循环、页面被系统回收但 WKWebView 实例还在）—— 那时原生插槽视图仍然
/// 显示，但 `slot/invoke` 全部无效：**用户点得到、点了没反应**，比白屏更糟。
///
/// 所以健康度是一个显式的四态，而不是一个 Bool：`suspect` 是「已经丢了一拍、
/// 还没判死」的那一段，UI 必须把它画出来（灰化 + 提示），不许静默失效。
public enum ControlLinkHealth: Hashable, Sendable, CustomStringConvertible {
    /// 还没开始探测（握手未完成 → 本来就不渲染原生插槽）。
    case unknown
    /// 最近一拍收到了 pong。
    case healthy
    /// 丢了 `misses` 拍，还没到判死阈值。
    case suspect(misses: Int)
    /// 连续丢够阈值 → 判定 client 半失联，已回落官方 Web UI。
    case lost(misses: Int)

    /// 原生插槽还在屏幕上，但控制通道已经不可靠 → 视图必须灰化。
    public var isSuspect: Bool {
        if case .suspect = self { return true }
        return false
    }

    public var isLost: Bool {
        if case .lost = self { return true }
        return false
    }

    /// 给用户看的人话（nil = 不显示提示）。
    public var noticeText: String? {
        switch self {
        case .unknown, .healthy:
            nil
        case .suspect(let misses):
            "官方 UI 没有回应心跳（丢 \(misses) 拍）—— 原生插槽暂时不可靠"
        case .lost(let misses):
            "官方 UI 连续 \(misses) 拍未回应心跳 —— 已把界面交还给官方 Web UI"
        }
    }

    public var description: String {
        switch self {
        case .unknown: "unknown"
        case .healthy: "healthy"
        case .suspect(let misses): "suspect(\(misses))"
        case .lost(let misses): "lost(\(misses))"
        }
    }
}

/// 控制通道心跳：`surface/ping` ↔ `surface/pong`（known-gaps.md G-3）。
///
/// ## 消息格式
///
/// 契约 §1.3 的方法表里 **Native → Web 一整列都是 `req`**，所以主格式选
/// `req`：
///
/// ```jsonc
/// // Native → Web
/// { "v":1, "t":"req", "id":"01J…", "m":"surface/ping", "p":{ "seq":7, "sentAt":1755…} }
/// // Web → Native（主格式：普通回执）
/// { "v":1, "t":"res", "id":"01J…", "ok":true, "p":{ "seq":7 } }
/// ```
///
/// 同时**兼容**把 pong 写成单向事件的实现（`{v:1,t:"evt",m:"surface/pong",p:{seq}}`）：
/// 只要在本拍 ping 发出之后收到过任何 pong，这一拍就算活。理由是 G-3 要判定的
/// 是「对端还在跑事件循环吗」，而不是「对端用哪种信封回答」—— 在这一点上多认
/// 一种形态不会放过任何一个真正的半死状态。
///
/// ## 判定
///
/// 10s 一拍，连续 2 拍没有任何 pong → `lost`，动作与崩溃退位对齐：
/// **撤下所有原生插槽视图，让官方 Web UI 接管**（ADR-0004）。
@MainActor
@Observable
public final class SurfaceHeartbeat {
    /// 契约规定的心跳间隔（known-gaps.md G-3）。
    public static let interval: Duration = .seconds(10)
    /// 连续丢几拍判定失联。
    public static let missThreshold = 2

    public private(set) var health: ControlLinkHealth = .unknown
    /// 连续未回拍数（收到 pong 即归零）。
    public private(set) var consecutiveMisses = 0
    public private(set) var lastPongAt: Date?
    public private(set) var sentPingCount = 0
    public private(set) var pongCount = 0
    /// 回执里的 `seq` 与本拍不符的次数（诊断：对端在回旧拍）。
    public private(set) var staleReplyCount = 0

    private let channel: ControlChannel
    private let interval: Duration
    private let missThreshold: Int
    private let telemetry: any SurfaceTelemetry
    private let now: @Sendable () -> Date
    private let sleeper: SleepFunction

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var onLost: (@MainActor (Int) -> Void)?
    @ObservationIgnored private var sequence = 0

    public init(
        channel: ControlChannel,
        interval: Duration = SurfaceHeartbeat.interval,
        missThreshold: Int = SurfaceHeartbeat.missThreshold,
        telemetry: any SurfaceTelemetry = LoggingSurfaceTelemetry(),
        now: (@Sendable () -> Date)? = nil,
        // 同上：命名常量，不写闭包字面量默认值（DSHKit/InjectableClock.swift）。
        sleeper: SleepFunction? = nil
    ) {
        self.channel = channel
        self.interval = interval
        self.missThreshold = max(1, missThreshold)
        self.telemetry = telemetry
        self.now = now ?? SystemClock.now
        self.sleeper = sleeper ?? SystemSleep.duration
        // 对端可能主动发 pong（或把 pong 写成 evt）：一律当活体证据收下。
        channel.onPong = { [weak self] payload in
            self?.notePong(payload)
        }
    }

    deinit {
        loop?.cancel()
    }

    /// 开始探测。`onLost` 在判定失联时调用一次，随后循环自行停止
    /// —— 已经回落到官方 Web UI 了，再 ping 也没有下一个动作可做。
    public func start(onLost: @escaping @MainActor (Int) -> Void) {
        guard loop == nil else { return }
        self.onLost = onLost
        health = .healthy
        consecutiveMisses = 0
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 先等一拍再探：刚握完手的那一刻没必要立刻加一个 req。
                do { try await self.sleeper(self.interval) } catch { return }
                guard !Task.isCancelled else { return }
                let alive = await self.probeOnce()
                if !alive, self.health.isLost { return }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 单拍探测。返回「这一拍算不算活」。
    ///
    /// 公开出来是为了让测试逐拍推进，不依赖真实时钟。
    @discardableResult
    public func probeOnce() async -> Bool {
        sequence += 1
        sentPingCount += 1
        let seq = sequence
        let sentAt = now()
        let payload = JSONValue.object([
            "seq": .number(Double(seq)),
            "sentAt": .number(sentAt.timeIntervalSince1970.rounded()),
        ])

        do {
            let reply = try await channel.request(ControlMethod.surfacePing, payload: payload)
            if let echoed = reply["seq"]?.intValue, echoed != seq {
                staleReplyCount += 1
            }
            notePong(reply)
            return true
        } catch {
            // 回执没来。但对端也许用 `evt surface/pong` 回答了这一拍 ——
            // 只要 pong 落在本拍 ping 之后，就算活。
            if let lastPongAt, lastPongAt >= sentAt {
                markAlive()
                return true
            }
            markMiss(detail: String(describing: error))
            return false
        }
    }

    /// 收到 pong（回执或事件）。
    private func notePong(_ payload: JSONValue) {
        pongCount += 1
        markAlive()
        _ = payload
    }

    private func markAlive() {
        lastPongAt = now()
        consecutiveMisses = 0
        if !health.isLost {
            // 已经判死过就不复活：失联动作已经执行（原生插槽撤下、官方 UI
            // 接管），自动回摆会让界面在两种实现之间抖动。
            health = .healthy
        }
    }

    private func markMiss(detail: String) {
        guard !health.isLost else { return }
        consecutiveMisses += 1
        telemetry.heartbeatMissed(misses: consecutiveMisses, detail: detail)
        if consecutiveMisses >= missThreshold {
            health = .lost(misses: consecutiveMisses)
            let callback = onLost
            stop()
            callback?(consecutiveMisses)
        } else {
            health = .suspect(misses: consecutiveMisses)
        }
    }
}
