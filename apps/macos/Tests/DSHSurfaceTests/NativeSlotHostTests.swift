import Testing
import Foundation
import SwiftUI
@testable import DSHKit
@testable import DSHSurface

// MARK: - 测试替身

/// 记账用遥测。`SurfaceTelemetry` 要求 `Sendable`，所以用锁而不是 actor 隔离
/// —— 断言全在主线程读。
final class RecordingTelemetry: SurfaceTelemetry, @unchecked Sendable {
    private let lock = NSLock()
    private var _rejections: [SurfaceError] = []
    private var _faults: [BridgeFault] = []
    private var _drops: [String] = []
    private var _degradations: [DegradationReason] = []
    private var _drifts: [SlotContractDrift] = []
    private var _slotFailures: [SlotErrorReport] = []
    private var _domainViolations: [(slot: String, keys: [String])] = []
    private var _heartbeatMisses: [Int] = []
    private var _manifestOrigins: [String] = []
    private var _manifestNativeSlots: [[String]] = []

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var rejections: [SurfaceError] { sync { _rejections } }
    var faults: [BridgeFault] { sync { _faults } }
    var drops: [String] { sync { _drops } }
    var degradations: [DegradationReason] { sync { _degradations } }
    var drifts: [SlotContractDrift] { sync { _drifts } }
    var slotFailures: [SlotErrorReport] { sync { _slotFailures } }
    var domainViolations: [(slot: String, keys: [String])] { sync { _domainViolations } }
    var heartbeatMisses: [Int] { sync { _heartbeatMisses } }
    /// G-4：这一轮宿主到底按哪份 manifest 接管的。
    var manifestOrigins: [String] { sync { _manifestOrigins } }
    var manifestNativeSlots: [[String]] { sync { _manifestNativeSlots } }

    func slotFailed(_ report: SlotErrorReport) { sync { _slotFailures.append(report) } }
    func assemblyRejected(_ error: SurfaceError) { sync { _rejections.append(error) } }
    func inputRejected(_ fault: BridgeFault, raw: String) { sync { _faults.append(fault) } }
    func contractDrift(_ drift: SlotContractDrift) { sync { _drifts.append(drift) } }
    func degraded(_ reason: DegradationReason) { sync { _degradations.append(reason) } }
    func orchestrationDropped(_ note: String) { sync { _drops.append(note) } }
    func domainDataRejected(slot: String, keys: [String]) { sync { _domainViolations.append((slot, keys)) } }
    func heartbeatMissed(misses: Int, detail: String) { sync { _heartbeatMisses.append(misses) } }
    func manifestAdopted(origin: String, slots: [String]) {
        sync {
            _manifestOrigins.append(origin)
            _manifestNativeSlots.append(slots)
        }
    }
}

/// 假注入面：记录 `slot/invoke`，可注入失败。
@MainActor
final class RecordingInvocationSink: SlotInvocationSink {
    struct Call: Equatable {
        let slot: String
        let instanceID: String
        let action: String
        let args: [JSONValue]
    }

    var calls: [Call] = []
    var failure: (any Error)?

    @discardableResult
    func invoke(slot: String, instanceID: String, action: String, args: [JSONValue]) async throws -> JSONValue {
        calls.append(Call(slot: slot, instanceID: instanceID, action: action, args: args))
        if let failure { throw failure }
        return .object(["ok": .bool(true)])
    }
}

/// 工厂调用计数（用引用类型，避免在 escaping 工厂里捕获可变局部变量）。
@MainActor
final class FactoryCounter {
    var value = 0
}

@MainActor
func makeHost(
    manifest: SurfaceManifest = .w1Default,
    telemetry: RecordingTelemetry = RecordingTelemetry(),
    sink: RecordingInvocationSink? = nil,
    registerWorkspaces: Bool = true,
    counter: FactoryCounter? = nil
) -> (host: NativeSlotHost, telemetry: RecordingTelemetry, sink: RecordingInvocationSink) {
    let resolvedSink = sink ?? RecordingInvocationSink()
    let host = NativeSlotHost(telemetry: telemetry, invocationSink: resolvedSink)
    host.configure(manifest)
    if registerWorkspaces {
        host.register(W1.workspacesSlot) { _ in
            counter?.value += 1
            return AnyView(Text("native rail"))
        }
    }
    return (host, telemetry, resolvedSink)
}

@MainActor
func mountEvent(
    slot: String = W1.workspacesSlot,
    instance: String = "inst-1",
    key: String? = nil,
    props: [String: JSONValue] = [:],
    actions: [String] = []
) -> SurfaceEvent {
    .mount(SlotMount(slot: slot, instanceID: instance, key: key, scope: .root, props: props, actions: actions))
}

// MARK: - 测试

@Suite("NativeSlotHost：装配、幂等、ADR 执行点")
@MainActor
struct NativeSlotHostTests {
    @Test("ADR-0003：滚动容器内的 overlay 直接拒绝，不尽力渲染")
    func rejectsOverlayInsideScrollContainer() throws {
        let manifest = SurfaceManifest(slots: [
            W1.workspacesSlot: SlotEntry(mode: .native, placement: .overlay),
        ])
        let (host, telemetry, _) = makeHost(manifest: manifest)
        try host.handle(mountEvent())

        #expect(throws: SurfaceError.overlayInsideScrollContainer(slot: W1.workspacesSlot, instanceID: "inst-1")) {
            try host.handle(.rect(
                instanceID: "inst-1",
                rect: SlotRect(x: 0, y: 0, w: 260, h: 700),
                scrollable: true
            ))
        }
        #expect(telemetry.rejections.count == 1)
        // 被拒之后不许留下一个「差不多对」的几何。
        #expect(host.stage.mounted["inst-1"]?.frame == nil)
    }

    @Test("overlay + 非滚动容器：几何被采纳")
    func acceptsOverlayOutsideScrollContainer() throws {
        let manifest = SurfaceManifest(slots: [
            W1.workspacesSlot: SlotEntry(mode: .native, placement: .overlay),
        ])
        let (host, _, _) = makeHost(manifest: manifest)
        try host.handle(mountEvent())
        try host.handle(.rect(instanceID: "inst-1", rect: SlotRect(x: 4, y: 8, w: 260, h: 700), scrollable: false))
        #expect(host.stage.mounted["inst-1"]?.frame == CGRect(x: 4, y: 8, width: 260, height: 700))
    }

    @Test("evacuated 插槽上报几何是协议违规")
    func rejectsGeometryForEvacuatedSlot() throws {
        let (host, telemetry, _) = makeHost() // w1Default = evacuated
        try host.handle(mountEvent())
        #expect(throws: SurfaceError.geometryForEvacuatedPlacement(slot: W1.workspacesSlot, instanceID: "inst-1")) {
            try host.handle(.rect(instanceID: "inst-1", rect: SlotRect(x: 0, y: 0, w: 1, h: 1), scrollable: false))
        }
        #expect(telemetry.rejections.count == 1)
    }

    @Test("manifest 要原生但宿主没实现 → 大声失败（启动自检 + 挂载时）")
    func loudlyFailsWithoutNativeImplementation() throws {
        let (host, telemetry, _) = makeHost(registerWorkspaces: false)
        #expect(throws: SurfaceError.noNativeImplementation(slot: W1.workspacesSlot)) {
            try host.verifyImplementations(for: .w1Default)
        }
        #expect(throws: SurfaceError.noNativeImplementation(slot: W1.workspacesSlot)) {
            try host.handle(mountEvent())
        }
        #expect(telemetry.rejections.count == 2)
        #expect(host.stage.mounted.isEmpty)
    }

    @Test("安全边界：manifest 没声明为原生的插槽，Web 侧不能让我们接管")
    func refusesUndeclaredSlot() throws {
        let (host, telemetry, _) = makeHost()
        host.register("sidebar.settings") { _ in AnyView(Text("nope")) }
        #expect(throws: SurfaceError.slotNotConfigured(slot: "sidebar.settings")) {
            try host.handle(mountEvent(slot: "sidebar.settings", instance: "inst-2"))
        }
        #expect(telemetry.rejections == [.slotNotConfigured(slot: "sidebar.settings")])
    }

    @Test("幂等：props 早于 mount 到达被安全丢弃")
    func dropsPropsBeforeMount() throws {
        let (host, telemetry, _) = makeHost()
        try host.handle(.props(instanceID: "inst-1", patch: ["collapsed": .bool(true)]))
        #expect(host.droppedOrchestrationCount == 1)
        #expect(telemetry.drops.count == 1)

        try host.handle(mountEvent())
        // 早到的 props 不会被追认。
        #expect(host.instance("inst-1")?.props.collapsed == false)
    }

    @Test("幂等：unmount 之后仍收到 props / rect / unmount 都被安全丢弃")
    func dropsPropsAfterUnmount() throws {
        let (host, _, _) = makeHost()
        try host.handle(mountEvent())
        try host.handle(.unmount(instanceID: "inst-1"))
        #expect(host.stage.mounted.isEmpty)
        #expect(host.instance("inst-1") == nil)

        try host.handle(.props(instanceID: "inst-1", patch: ["collapsed": .bool(true)]))
        try host.handle(.unmount(instanceID: "inst-1"))
        try host.handle(.rect(instanceID: "inst-1", rect: SlotRect(x: 0, y: 0, w: 1, h: 1), scrollable: false))
        #expect(host.droppedOrchestrationCount == 3)
    }

    @Test("幂等：同 instanceId 重复 mount = props 刷新，不重建视图")
    func duplicateMountRefreshesProps() throws {
        let counter = FactoryCounter()
        let (host, _, _) = makeHost(counter: counter)
        try host.handle(mountEvent(props: ["collapsed": .bool(false)], actions: ["startSession"]))
        let first = host.instance("inst-1")

        try host.handle(mountEvent(props: ["collapsed": .bool(true)], actions: ["startSession", "selectSession"]))
        #expect(counter.value == 1)
        #expect(host.instance("inst-1") === first)
        #expect(host.instance("inst-1")?.props.collapsed == true)
        #expect(host.instance("inst-1")?.actions == ["startSession", "selectSession"])
        #expect(host.stage.mounted.count == 1)
        #expect(host.droppedOrchestrationCount == 1) // 重复 mount 记账
    }

    @Test("props 浅 merge，null 表示删除")
    func mergesPropsShallowly() throws {
        let (host, _, _) = makeHost()
        try host.handle(mountEvent(props: ["collapsed": .bool(true), "label": .string("工作区")]))
        try host.handle(.props(instanceID: "inst-1", patch: ["label": .null, "width": .number(300)]))
        let instance = try #require(host.instance("inst-1"))
        #expect(instance.props.collapsed == true)
        #expect(instance.props.label == nil)
        #expect(instance.props.width == 300)
    }

    @Test("ADR-0002：白名单外的 props（领域数据）被丢弃并告警")
    func rejectsDomainPropsOnControlChannel() throws {
        let (host, telemetry, _) = makeHost()
        try host.handle(mountEvent(props: [
            "collapsed": .bool(true),
            "sessions": .array([.object(["id": .string("s-1")])]),
            "workspaceTitle": .string("demo"),
        ]))
        let instance = try #require(host.instance("inst-1"))
        #expect(instance.props["sessions"] == nil)
        #expect(instance.props.collapsed == true)
        #expect(host.domainFieldsSeen == ["sidebar.workspaces.sessions", "sidebar.workspaces.workspaceTitle"])
        #expect(telemetry.domainViolations.first?.keys == ["sessions", "workspaceTitle"])

        try host.handle(.props(instanceID: "inst-1", patch: ["messages": .array([])]))
        #expect(instance.props["messages"] == nil)
        #expect(telemetry.domainViolations.count == 2)
    }

    @Test("崩溃退位：记账 + 撤下自己的视图（不和官方实现抢着画）")
    func recordsAbdication() throws {
        let (host, telemetry, _) = makeHost()
        try host.handle(mountEvent())
        try host.handle(.error(SlotErrorReport(
            slot: W1.workspacesSlot,
            instanceID: "inst-1",
            error: "render threw",
            abdicated: true
        )))
        #expect(host.abdicationCount == 1)
        #expect(host.stage.mounted.isEmpty)
        #expect(telemetry.slotFailures.count == 1)
        #expect(host.instance("inst-1") == nil)
    }

    @Test("非退位的 slot/error 只上报，不撤视图")
    func nonAbdicatedErrorKeepsView() throws {
        let (host, telemetry, _) = makeHost()
        try host.handle(mountEvent())
        try host.handle(.error(SlotErrorReport(slot: W1.workspacesSlot, instanceID: "inst-1", error: "warn", abdicated: false)))
        #expect(host.abdicationCount == 0)
        #expect(host.stage.mounted.count == 1)
        #expect(telemetry.slotFailures.count == 1)
    }

    @Test("slot/invoke 守卫：未声明的动作被拒")
    func refusesUndeclaredAction() async throws {
        let (host, _, sink) = makeHost()
        try host.handle(mountEvent(actions: ["startSession"]))
        let instance = try #require(host.instance("inst-1"))

        await #expect(throws: SurfaceError.actionNotDeclared(slot: W1.workspacesSlot, action: "deleteEverything")) {
            _ = try await instance.invoke("deleteEverything")
        }
        #expect(sink.calls.isEmpty)

        _ = try await instance.invoke("startSession", [.string("s-1")])
        #expect(sink.calls == [RecordingInvocationSink.Call(
            slot: W1.workspacesSlot,
            instanceID: "inst-1",
            action: "startSession",
            args: [.string("s-1")]
        )])
    }

    @Test("slot/invoke 守卫：mirrored（不赢渲染权）的实例不许 invoke")
    func refusesInvokeFromMirroredSlot() async throws {
        let manifest = SurfaceManifest(slots: [W1.workspacesSlot: SlotEntry(mode: .mirrored)])
        let (host, _, sink) = makeHost(manifest: manifest)
        try host.handle(mountEvent(actions: ["startSession"]))
        let instance = try #require(host.instance("inst-1"))
        #expect(host.stage.mounted["inst-1"]?.presentation == .offscreenComparison)
        #expect(host.stage.visibleInstance(of: W1.workspacesSlot) == nil)

        await #expect(throws: SurfaceError.invokeOnNonNativeSlot(slot: W1.workspacesSlot, action: "startSession")) {
            _ = try await instance.invoke("startSession")
        }
        #expect(sink.calls.isEmpty)
    }

    @Test("unmount 后的实例不再 invoke")
    func retiredInstanceRefusesInvoke() async throws {
        let (host, _, sink) = makeHost()
        try host.handle(mountEvent(actions: ["startSession"]))
        let instance = try #require(host.instance("inst-1"))
        try host.handle(.unmount(instanceID: "inst-1"))
        #expect(instance.isLive == false)
        await #expect(throws: SurfaceError.slotNotMounted(instanceID: "inst-1")) {
            _ = try await instance.invoke("startSession")
        }
        #expect(sink.calls.isEmpty)
    }

    @Test("invoke 失败会留在实例上，UI 可以提示而不是静默失效")
    func recordsInvokeFailure() async throws {
        let sink = RecordingInvocationSink()
        sink.failure = ControlChannelError.timedOut(method: ControlMethod.slotInvoke, after: .seconds(5))
        let (host, _, _) = makeHost(sink: sink)
        try host.handle(mountEvent(actions: ["startSession"]))
        let instance = try #require(host.instance("inst-1"))
        _ = try? await instance.invoke("startSession")
        #expect(instance.lastInvokeFailure != nil)
    }

    @Test("keyed 插槽：多个实例并存，按 instanceId 追踪")
    func tracksMultipleInstances() throws {
        let manifest = SurfaceManifest(slots: [
            "tab.body": SlotEntry(mode: .native, keys: [
                "chat": SlotEntry(mode: .native),
                "diff": SlotEntry(mode: .web),
            ]),
        ])
        let (host, telemetry, _) = makeHost(manifest: manifest, registerWorkspaces: false)
        host.register("tab.body") { _ in AnyView(Text("body")) }
        try host.handle(.mount(SlotMount(slot: "tab.body", instanceID: "i-chat", key: "chat", scope: .session)))
        // `diff` 这个 key 被覆盖成 web → 不许接管。
        #expect(throws: SurfaceError.slotNotConfigured(slot: "tab.body")) {
            try host.handle(.mount(SlotMount(slot: "tab.body", instanceID: "i-diff", key: "diff", scope: .session)))
        }
        #expect(host.stage.instances(of: "tab.body").map(\.id) == ["i-chat"])
        #expect(telemetry.rejections.count == 1)
    }

    @Test("unmountAll(of:) 清空某插槽（热切换回官方 UI 时用）")
    func unmountsAllInstancesOfSlot() throws {
        let (host, _, _) = makeHost()
        try host.handle(mountEvent(instance: "inst-1"))
        try host.handle(mountEvent(instance: "inst-2"))
        #expect(host.stage.mounted.count == 2)
        host.unmountAll(of: W1.workspacesSlot)
        #expect(host.stage.mounted.isEmpty)
        #expect(host.instance("inst-1") == nil)
        #expect(host.instance("inst-2") == nil)
    }

    @Test("编排 props 白名单本身就是 ADR-0002 的可执行形式")
    func orchestrationWhitelistIsClosed() {
        let (kept, rejected) = OrchestrationProps.split([
            "collapsed": .bool(true),
            "selected": .string("s-1"),
            "width": .number(260),
            "sessionList": .array([]),
            "title": .string("会话标题"),
        ])
        #expect(Set(kept.keys) == ["collapsed", "selected", "width"])
        #expect(rejected == ["sessionList", "title"]) // 会话标题也是领域数据，走数据通道
    }
}
