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

    public private(set) var phase: Phase = .launching
    public private(set) var manifest: SurfaceManifest
    /// `surface/ready` 带来的实测插槽表。
    public private(set) var measuredSlots: [DeclaredSlot] = []
    public private(set) var lastConfigureResult: ConfigureResult?
    /// 运行时契约漂移（ARCHITECTURE.md §7）。
    public private(set) var drift: SlotContractDrift?

    private let channel: ControlChannel
    private let host: NativeSlotHost
    private let snapshot: SlotContractSnapshot
    private let telemetry: any SurfaceTelemetry
    private let handshakeTimeout: Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    @ObservationIgnored private var watchdog: Task<Void, Never>?

    public init(
        channel: ControlChannel,
        host: NativeSlotHost,
        manifest: SurfaceManifest = .w1Default,
        snapshot: SlotContractSnapshot = .w1,
        telemetry: any SurfaceTelemetry = LoggingSurfaceTelemetry(),
        handshakeTimeout: Duration = SurfaceCoordinator.handshakeWindow,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.channel = channel
        self.host = host
        self.manifest = manifest
        self.snapshot = snapshot
        self.telemetry = telemetry
        self.handshakeTimeout = handshakeTimeout
        self.sleeper = sleeper
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

        // 运行时漂移检测：实测插槽表 vs 编译期快照。告警，不降级 ——
        // 上游新增插槽自动落到 `web`，本身是安全的。
        let targeted = Set(manifest.slots.filter { $0.value.mode.mountsNativeView }.keys)
        if let detected = snapshot.drift(against: ready.slots, interestedIn: targeted) {
            drift = detected
            telemetry.contractDrift(detected)
        } else {
            drift = nil
        }

        phase = .configuring(protocolVersion: ready.protocolVersion)
        Task { @MainActor [weak self] in
            await self?.sendConfigure(protocolVersion: ready.protocolVersion)
        }
    }

    private func sendConfigure(protocolVersion: Int) async {
        do {
            let payload = try manifest.configurePayload
            let reply = try await channel.request(ControlMethod.surfaceConfigure, payload: payload)
            let result = try ConfigureResult.decode(reply)
            lastConfigureResult = result

            let targeted = manifest.slots.filter { $0.value.mode.mountsNativeView }.keys.sorted()
            let rejected = Set(result.rejected.map(\.slot))
            if !targeted.isEmpty, targeted.allSatisfy(rejected.contains) {
                // 我们想接管的每一格都被拒了 → 原生侧无事可做，老实降级。
                degrade(.configureFailed(result.rejected.map { "\($0.slot): \($0.reason)" }.joined(separator: "; ")))
                return
            }
            for rejection in result.rejected {
                telemetry.assemblyRejected(.slotNotConfigured(slot: rejection.slot))
            }
            phase = .live(protocolVersion: protocolVersion)
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

    // MARK: 降级

    private func degrade(_ reason: DegradationReason) {
        if case .degradedWebOnly = phase { return }
        telemetry.degraded(reason)
        host.unmountAllSlots()
        phase = .degradedWebOnly(reason)
    }
}
