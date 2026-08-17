import SwiftUI
import DSHKit

/// 按 slot 名注册视图工厂；实例按 `instanceId` 追踪。
///
/// 这是 reference/native-slot-proxy.md §4 的真实实现。
///
/// 注意：视图工厂只拿到**编排 props**，领域数据由视图自己从 `DSHClient`
/// （数据通道）取 —— `DSHSurface` 不碰领域数据（ADR-0002）。
@MainActor
public final class NativeSlotHost {
    public typealias Factory = @MainActor (SlotInstance) -> AnyView

    public let stage: SlotStage

    private var factories: [String: Factory] = [:]
    private var live: [String: SlotInstance] = [:]
    private var manifest: SurfaceManifest = .empty
    private let telemetry: any SurfaceTelemetry
    private weak var invocationSink: (any SlotInvocationSink)?

    /// 记账：崩溃退位次数（migration-playbook.md §⑥ 的红线信号，任意一次即回退调查）。
    public private(set) var abdicationCount = 0
    /// 记账：被安全丢弃的编排事件数（早到/晚到/重复）。
    public private(set) var droppedOrchestrationCount = 0
    /// 记账：控制通道上出现过的领域字段（ADR-0002 的硬性 review 项）。
    public private(set) var domainFieldsSeen: [String] = []

    public init(
        stage: SlotStage = SlotStage(),
        telemetry: any SurfaceTelemetry = LoggingSurfaceTelemetry(),
        invocationSink: (any SlotInvocationSink)? = nil
    ) {
        self.stage = stage
        self.telemetry = telemetry
        self.invocationSink = invocationSink
    }

    public func attach(invocationSink: any SlotInvocationSink) {
        self.invocationSink = invocationSink
    }

    /// 注册某个插槽的原生视图工厂。
    public func register(_ slot: String, _ make: @escaping Factory) {
        factories[slot] = make
    }

    public func register<V: View>(_ slot: String, @ViewBuilder view make: @escaping @MainActor (SlotInstance) -> V) {
        factories[slot] = { instance in AnyView(make(instance)) }
    }

    public var registeredSlots: Set<String> { Set(factories.keys) }

    public func configure(_ manifest: SurfaceManifest) {
        self.manifest = manifest
    }

    public func instance(_ instanceID: String) -> SlotInstance? {
        live[instanceID]
    }

    /// 启动期自检：manifest 说要原生，但宿主没有实现 → **大声失败**。
    ///
    /// 不等第一次 `slot/mount` 才发现 —— 那时候用户已经在看一块空白了。
    public func verifyImplementations(for manifest: SurfaceManifest) throws {
        for (slot, entry) in manifest.slots.sorted(by: { $0.key < $1.key }) where entry.mode.mountsNativeView {
            guard factories[slot] != nil else {
                let error = SurfaceError.noNativeImplementation(slot: slot)
                telemetry.assemblyRejected(error)
                throw error
            }
        }
    }

    /// 处理一条 Web→Native 的编排事件。
    ///
    /// 幂等原则（bridge-contract.md §1.4）：控制通道是幂等编排，不做事务。
    /// 必须容忍 props 早到 / unmount 后仍收到 props / 同 instanceId 重复 mount。
    public func handle(_ event: SurfaceEvent) throws {
        switch event {
        case .mount(let mount):
            try handleMount(mount)

        case .rect(let instanceID, let rect, let scrollable):
            // ── ADR-0003 的执行点 ────────────────────────────────────
            // 滚动容器内不许 overlay。不「尽力渲染」，直接失败 ——
            // 漂移是视觉撕裂，比崩溃更难发现、对用户更像坏产品。
            if scrollable {
                let error = SurfaceError.overlayInsideScrollContainer(
                    slot: live[instanceID]?.slot ?? "?",
                    instanceID: instanceID
                )
                telemetry.assemblyRejected(error)
                throw error
            }
            guard let instance = live[instanceID] else {
                drop("slot/rect for unknown instance \(instanceID)")
                return
            }
            guard instance.placement == .overlay else {
                // evacuated 插槽不该上报几何：Web 侧代理写错了，或者不是我们的代理。
                let error = SurfaceError.geometryForEvacuatedPlacement(
                    slot: instance.slot,
                    instanceID: instanceID
                )
                telemetry.assemblyRejected(error)
                throw error
            }
            stage.position(instanceID, to: rect)

        case .props(let instanceID, let patch):
            guard let instance = live[instanceID] else {
                // props 早于 mount 到达，或者 unmount 之后还在来 —— 一律安全丢弃。
                drop("slot/props for instance \(instanceID) that is not live")
                return
            }
            let (kept, rejected) = OrchestrationProps.split(patch)
            if !rejected.isEmpty {
                // ADR-0002：领域数据不许过控制通道。丢掉并记账，不「先用着」。
                domainFieldsSeen.append(contentsOf: rejected.map { "\(instance.slot).\($0)" })
                telemetry.domainDataRejected(slot: instance.slot, keys: rejected)
            }
            if !kept.isEmpty {
                instance.applyProps(kept)
            }

        case .unmount(let instanceID):
            guard let instance = live.removeValue(forKey: instanceID) else {
                drop("slot/unmount for unknown instance \(instanceID)")
                return
            }
            instance.retire()
            stage.remove(instanceID)

        case .error(let report):
            // 官方的崩溃退位机制接到宿主遥测：让「悄悄回落」变成「记账的回落」。
            telemetry.slotFailed(report)
            if report.abdicated {
                abdicationCount += 1
                // 官方 Web 实现已自动接管这一格（ADR-0004）。我们不做补救，
                // 但要把自己那个已经死掉的视图从舞台上撤下来，免得两份都画。
                if let instanceID = report.instanceID, let instance = live.removeValue(forKey: instanceID) {
                    instance.retire()
                    stage.remove(instanceID)
                }
            }
        }
    }

    private func handleMount(_ mount: SlotMount) throws {
        let entry = manifest.entry(for: mount.slot, key: mount.key)

        // 安全边界（bridge-contract.md §5）：WebView 不能自己决定接管哪一格。
        guard entry.mode.mountsNativeView else {
            let error = SurfaceError.slotNotConfigured(slot: mount.slot)
            telemetry.assemblyRejected(error)
            throw error
        }
        guard let make = factories[mount.slot] else {
            // manifest 说要原生，但宿主没有实现 → 大声失败。
            let error = SurfaceError.noNativeImplementation(slot: mount.slot)
            telemetry.assemblyRejected(error)
            throw error
        }

        let (props, rejectedKeys) = OrchestrationProps.split(mount.props)
        if !rejectedKeys.isEmpty {
            domainFieldsSeen.append(contentsOf: rejectedKeys.map { "\(mount.slot).\($0)" })
            telemetry.domainDataRejected(slot: mount.slot, keys: rejectedKeys)
        }

        // 同一个 instanceId 重复 mount → 视为 props 刷新（§1.4），不重建视图。
        if let existing = live[mount.instanceID] {
            existing.applyProps(props)
            existing.replaceActions(mount.actions)
            drop("duplicate slot/mount for instance \(mount.instanceID) treated as a props refresh")
            return
        }

        let sanitized = SlotMount(
            slot: mount.slot,
            instanceID: mount.instanceID,
            key: mount.key,
            scope: mount.scope,
            props: props,
            actions: mount.actions
        )
        let instance = SlotInstance(
            mount: sanitized,
            placement: entry.placement,
            mode: entry.mode,
            invoker: { [weak self] instance, action, args in
                guard let self else { throw SurfaceError.slotNotMounted(instanceID: instance.id) }
                return try await self.forward(instance: instance, action: action, args: args)
            }
        )
        live[mount.instanceID] = instance
        stage.insert(SlotStage.Mounted(
            instance: instance,
            view: make(instance),
            presentation: entry.mode == .mirrored ? .offscreenComparison : .visible,
            frame: nil
        ))
    }

    /// `slot/invoke` 的守卫（bridge-contract.md §5）：
    /// 只能触达 manifest 里声明为 native 的插槽实例的注入面。
    private func forward(instance: SlotInstance, action: String, args: [JSONValue]) async throws -> JSONValue {
        guard instance.mode.ownsRendering else {
            throw SurfaceError.invokeOnNonNativeSlot(slot: instance.slot, action: action)
        }
        guard instance.can(action) else {
            throw SurfaceError.actionNotDeclared(slot: instance.slot, action: action)
        }
        guard let invocationSink else {
            throw SurfaceError.slotNotMounted(instanceID: instance.id)
        }
        return try await invocationSink.invoke(
            slot: instance.slot,
            instanceID: instance.id,
            action: action,
            args: args
        )
    }

    /// 撤下某个插槽的全部实例（热切换回 web 时用）。
    public func unmountAll(of slot: String) {
        for (instanceID, instance) in live where instance.slot == slot {
            instance.retire()
            live.removeValue(forKey: instanceID)
            stage.remove(instanceID)
        }
    }

    /// 撤下全部实例（降级为纯官方 Web UI 时用）。
    public func unmountAllSlots() {
        for (instanceID, instance) in live {
            instance.retire()
            stage.remove(instanceID)
            live.removeValue(forKey: instanceID)
        }
    }

    private func drop(_ note: String) {
        droppedOrchestrationCount += 1
        telemetry.orchestrationDropped(note)
    }
}
