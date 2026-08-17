import Foundation
import DSHKit

/// 握手 + manifest 下发 + 热切换的协调器。
///
/// bridge-contract.md §1.1：握手由 **Web 侧发起**（client 插件的加载时机由
/// `BootManifest` 决定，宿主无法预知）。宿主在收到 `surface/ready` 前不渲染
/// 任何原生插槽视图，只显示启动态；**15s 未收到 → 判定 client 半未加载，
/// 进入「纯官方 Web UI」降级模式并上报**。
@MainActor
@Observable
public final class SurfaceCoordinator {
    /// 契约规定的握手窗口。
    public static let handshakeWindow: Duration = .seconds(15)

    public enum Phase: Hashable, Sendable {
        /// 还没握上手 —— 一个原生插槽视图都不许渲染。
        case launching
        /// 已握手，正在下发 manifest。
        case configuring(protocolVersion: Int)
        /// 原生插槽可以渲染了。
        case live(protocolVersion: Int)
        /// 纯官方 Web UI（ADR-0004 的回落）。
        case degradedWebOnly(DegradationReason)

        /// 原生插槽视图是否可以出现在屏幕上。
        public var rendersNativeSlots: Bool {
            if case .live = self { return true }
            return false
        }
    }

    /// manifest 的来源（G-4：**唯一真相源是 runtime 那份**）。
    public enum ManifestOrigin: Hashable, Sendable, CustomStringConvertible {
        /// 编译进 Swift 的兜底（`SurfaceManifest.w1Default`）。
        case compiledFallback
        /// runtime 的 `GET /studio/surface` —— 也就是 profile 里那份 YAML。
        case runtimeAuthority
        /// 拿到了 runtime 那份但拒绝采纳（它要求的原生实现宿主没有）。
        case rejectedRuntime(String)

        public var description: String {
            switch self {
            case .compiledFallback: "compiled fallback (SurfaceManifest.w1Default)"
            case .runtimeAuthority: "runtime authority (GET /studio/surface)"
            case .rejectedRuntime(let detail): "runtime manifest refused: \(detail)"
            }
        }
    }

    /// 权威 manifest 的来源缝。
    ///
    /// 声明成一个闭包而不是「宿主自己去发 HTTP」，是为了让编排层不认识数据
    /// 通道：ADR-0002 禁止本 target 出现任何 HTTP 客户端类型或 runtime 路由
    /// 字面量，`ArchitectureGuardTests` 会逐字扫源码。真实实现住在 `DSHApp`
    /// —— 那里本来就是唯一同时认识两条通道的地方。返回 `nil` = 拿不到，用兜底。
    public typealias ManifestSource = @Sendable () async -> SurfaceManifest?

    public private(set) var phase: Phase = .launching
    public private(set) var manifest: SurfaceManifest
    /// 当前 manifest 从哪来（G-4）。dogfood 时第一个要回答的问题就是
    /// 「它用的是我改的那份 YAML，还是编译进去的兜底」。
    public private(set) var manifestOrigin: ManifestOrigin = .compiledFallback
    /// `surface/ready` 带来的实测插槽表。
    public private(set) var measuredSlots: [DeclaredSlot] = []
    public private(set) var lastConfigureResult: ConfigureResult?
    /// 运行时契约漂移（ARCHITECTURE.md §7）。
    public private(set) var drift: SlotContractDrift?
    /// 运行期控制通道健康度（known-gaps.md G-3）。UI 用它决定要不要灰化。
    public var controlLinkHealth: ControlLinkHealth { heartbeat.health }

    /// 运行期心跳（G-3）。启动期由 `watchdog` 覆盖，`live` 之后交给它。
    public let heartbeat: SurfaceHeartbeat

    private let channel: ControlChannel
    private let host: NativeSlotHost
    private let snapshot: SlotContractSnapshot
    private let telemetry: any SurfaceTelemetry
    private let handshakeTimeout: Duration
    private let sleeper: SleepFunction
    /// 握手后去 runtime 取权威 manifest（G-4）。`nil` = 只用编译期兜底。
    private let manifestSource: ManifestSource?

    @ObservationIgnored private var watchdog: Task<Void, Never>?

    public init(
        channel: ControlChannel,
        host: NativeSlotHost,
        manifest: SurfaceManifest = .w1Default,
        snapshot: SlotContractSnapshot = .w1,
        telemetry: any SurfaceTelemetry = LoggingSurfaceTelemetry(),
        handshakeTimeout: Duration = SurfaceCoordinator.handshakeWindow,
        // 默认值走 `SystemSleep.duration` 这个命名常量。写成默认参数里的闭包
        // 字面量会让看门狗任务在被取消时整个进程 abort，而且只在生产路径上炸
        // （单测一贯注入假时钟）—— 见 DSHKit/InjectableClock.swift 与 G-6。
        sleeper: SleepFunction? = nil,
        heartbeat: SurfaceHeartbeat? = nil,
        manifestSource: ManifestSource? = nil
    ) {
        self.channel = channel
        self.host = host
        self.manifest = manifest
        self.snapshot = snapshot
        self.telemetry = telemetry
        self.handshakeTimeout = handshakeTimeout
        self.sleeper = sleeper ?? SystemSleep.duration
        self.manifestSource = manifestSource
        // 心跳自带时钟：不复用 `sleeper`（测试常把它换成「立刻返回」，那会把
        // 10s 一拍变成忙等）。
        self.heartbeat = heartbeat ?? SurfaceHeartbeat(channel: channel, telemetry: telemetry)
        host.configure(manifest)
        host.attach(invocationSink: channel)
    }

    deinit {
        watchdog?.cancel()
    }

    /// 接线并开始等握手。
    ///
    /// 会先做一次启动自检：manifest 说要原生但宿主没实现 → 直接抛错
    /// （大声失败，不等用户看到空白）。
    public func start() throws {
        try host.verifyImplementations(for: manifest)

        channel.onReady = { [weak self] ready in
            self?.handleReady(ready)
        }
        channel.onSlotEvent = { [weak self] event in
            guard let self else { return }
            guard self.phase.rendersNativeSlots || self.isPreConfigure(event) else {
                // 降级之后仍然收到编排事件：官方 UI 已经接管，安全丢弃。
                self.telemetry.orchestrationDropped("slot event while phase=\(self.phase)")
                return
            }
            try self.host.handle(event)
        }
        channel.onProtocolMismatch = { [weak self] version in
            self?.degrade(.protocolMismatch(peer: version))
        }

        watchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.sleeper(self.handshakeTimeout)
            guard !Task.isCancelled else { return }
            if case .launching = self.phase {
                // 15s 没有 surface/ready → client 半没加载。
                self.degrade(.handshakeTimeout(self.handshakeTimeout))
            }
        }
    }

    public func stop() {
        watchdog?.cancel()
        watchdog = nil
        heartbeat.stop()
    }

    /// `configuring` 阶段允许 mount 先到（Web 侧注册与回执是并发的）。
    private func isPreConfigure(_ event: SurfaceEvent) -> Bool {
        if case .configuring = phase { return true }
        return false
    }

    // MARK: 握手

    private func handleReady(_ ready: SurfaceReady) {
        watchdog?.cancel()
        watchdog = nil
        measuredSlots = ready.slots

        guard ready.protocolVersion == BridgeProtocol.current else {
            // 不猜、不适配：半懂协议的两端会把状态搞坏（bridge-contract.md §4）。
            degrade(.protocolMismatch(peer: ready.protocolVersion))
            return
        }

        phase = .configuring(protocolVersion: ready.protocolVersion)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 先取权威 manifest，再做漂移检测 —— 否则会拿兜底那份去判漂移，
            // 而用户真正生效的是 runtime 那份（G-4）。
            await self.adoptRuntimeManifest()
            self.detectDrift(against: ready.slots)
            await self.sendConfigure(protocolVersion: ready.protocolVersion)
        }
    }

    /// 从 runtime 取权威 manifest 并采纳（G-4）。
    ///
    /// 三种结果都不致命：
    /// - 拿不到（runtime 未起 / 404 / token 失效）→ 用编译期兜底，记账；
    /// - 拿到但它要求的原生实现宿主没有 → **拒绝采纳**并留在兜底上。用户改错
    ///   一行 YAML 不该让 app 起不来（这与编译期兜底的「大声失败」不同：那份
    ///   出错是我们的 bug，这份出错是配置）；
    /// - 拿到且可实现 → 采纳，`manifestOrigin = .runtimeAuthority`。
    private func adoptRuntimeManifest() async {
        guard let manifestSource else { return }
        guard let remote = await manifestSource() else {
            telemetry.manifestAdopted(origin: ManifestOrigin.compiledFallback.description, slots: manifest.slotsRequiringNativeView)
            return
        }
        do {
            try host.verifyImplementations(for: remote)
        } catch {
            let detail = String(describing: error)
            manifestOrigin = .rejectedRuntime(detail)
            telemetry.manifestAdopted(origin: ManifestOrigin.rejectedRuntime(detail).description, slots: manifest.slotsRequiringNativeView)
            return
        }
        manifest = remote
        host.configure(remote)
        manifestOrigin = .runtimeAuthority
        telemetry.manifestAdopted(origin: ManifestOrigin.runtimeAuthority.description, slots: remote.slotsRequiringNativeView)
    }

    /// 运行时漂移检测：实测插槽表 vs 编译期快照。告警，不降级 ——
    /// 上游新增插槽自动落到 `web`，本身是安全的。
    private func detectDrift(against measured: [DeclaredSlot]) {
        let targeted = Set(manifest.slotsRequiringNativeView)
        if let detected = snapshot.drift(against: measured, interestedIn: targeted) {
            drift = detected
            telemetry.contractDrift(detected)
        } else {
            drift = nil
        }
    }

    private func sendConfigure(protocolVersion: Int) async {
        do {
            let payload = try manifest.configurePayload
            let reply = try await channel.request(ControlMethod.surfaceConfigure, payload: payload)
            let result = try ConfigureResult.decode(reply)
            lastConfigureResult = result

            // 只对「真要渲染的那些格」较真：暗槽被拒也不影响用户看到什么
            // （它本来就永不渲染），但它若被拒说明规则 7 没满足，仍会记账。
            let targeted = manifest.slotsRequiringNativeView
            let rejected = Set(result.rejected.map(\.slot))
            if !targeted.isEmpty, targeted.allSatisfy(rejected.contains) {
                // 我们想接管的每一格都被拒了 → 原生侧无事可做，老实降级。
                degrade(.configureFailed(result.rejected.map(\.logLine).joined(separator: "; ")))
                return
            }
            for rejection in result.rejected {
                telemetry.assemblyRejected(
                    .configureRejected(slot: rejection.slot, reason: rejection.reason, detail: rejection.detail)
                )
            }
            phase = .live(protocolVersion: protocolVersion)
            // 只有到了 live 才开始心跳：之前一个原生插槽都没渲染，
            // 「点得到但点不动」这个问题不存在。
            startHeartbeat()
        } catch {
            degrade(.configureFailed(String(describing: error)))
        }
    }

    // MARK: 热切换（⌥⇧D 的后端）

    /// 运行时改单个插槽的 mode，**不重启、不刷新页面**（surface-manifest.md §5）。
    @discardableResult
    public func reconfigure(slot: String, mode: SlotMode) async -> Bool {
        var entry = manifest.entry(for: slot)
        entry.mode = mode
        var patch = SurfaceManifest()
        patch.set(entry, for: slot)

        do {
            if mode.mountsNativeView {
                // 切回原生前先确认真有实现，别把用户切进一块空白。
                var probe = SurfaceManifest()
                probe.set(entry, for: slot)
                try host.verifyImplementations(for: probe)
            }
            _ = try await channel.request(
                ControlMethod.surfaceReconfigure,
                payload: try patch.reconfigurePayload
            )
            manifest = manifest.applying(patch: patch)
            host.configure(manifest)
            if !mode.mountsNativeView {
                // Web 侧会发 slot/unmount，但不等它 —— 立刻把舞台清干净，
                // 避免热切换留下残留视图（migration-playbook.md §⑤ 验收门）。
                host.unmountAll(of: slot)
            }
            return true
        } catch {
            telemetry.assemblyRejected(.slotNotConfigured(slot: slot))
            return false
        }
    }

    /// `⌥⇧D` 的语义：把插槽在 native / web 之间来回翻。
    @discardableResult
    public func toggleMode(for slot: String) async -> SlotMode? {
        let current = manifest.entry(for: slot).mode
        let next: SlotMode = current.ownsRendering ? .web : .native
        return await reconfigure(slot: slot, mode: next) ? next : nil
    }

    /// 查询某插槽当前占有者与 priority（诊断用）。
    public func probe(slot: String) async throws -> JSONValue {
        try await channel.request(ControlMethod.slotProbe, payload: .object(["slot": .string(slot)]))
    }

    // MARK: 运行期心跳（G-3）

    /// `live` 之后每 10s 一拍 `surface/ping`；连续 2 拍无 pong → 判定 client 半
    /// 失联，**撤下所有原生插槽视图，让官方 Web UI 接管**（与崩溃退位对齐）。
    private func startHeartbeat() {
        heartbeat.start { [weak self] misses in
            guard let self else { return }
            self.degrade(.controlLinkLost(misses: misses, interval: SurfaceHeartbeat.interval))
        }
    }

    // MARK: 降级

    private func degrade(_ reason: DegradationReason) {
        if case .degradedWebOnly = phase { return }
        telemetry.degraded(reason)
        heartbeat.stop()
        host.unmountAllSlots()
        phase = .degradedWebOnly(reason)
    }
}
