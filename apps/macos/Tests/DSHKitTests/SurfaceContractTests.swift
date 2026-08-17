import Testing
import Foundation
@testable import DSHKit

@Suite("Web→Native 编排事件解码（不可信输入边界，bridge-contract.md §5）")
struct SurfaceEventDecoderTests {
    private func payload(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    @Test("正常 mount 解出 slot / instanceId / scope / actions")
    func decodesMount() throws {
        let event = try SurfaceEventDecoder.decode(method: ControlMethod.slotMount, payload: payload([
            "slot": .string("sidebar.workspaces"),
            "instanceId": .string("inst-1"),
            "scope": .string("root"),
            "props": .object(["collapsed": .bool(true), "selected": .string("s-1")]),
            "actions": .array([.string("startSession"), .string("selectSession")]),
        ]))
        guard case .mount(let mount) = event else {
            Issue.record("expected mount, got \(event)")
            return
        }
        #expect(mount.slot == "sidebar.workspaces")
        #expect(mount.instanceID == "inst-1")
        #expect(mount.scope == .root)
        #expect(mount.actions == ["startSession", "selectSession"])
        #expect(mount.props["collapsed"] == .bool(true))
    }

    @Test("未知 scope 被拒绝（scope 是行为关键字段，不兜底）")
    func rejectsUnknownScope() {
        #expect(throws: BridgeFault.self) {
            try SurfaceEventDecoder.decode(method: ControlMethod.slotMount, payload: .object([
                "slot": .string("sidebar.workspaces"),
                "instanceId": .string("inst-1"),
                "scope": .string("multiverse"),
            ]))
        }
    }

    @Test("非法 instanceId / slot 名被拒绝")
    func rejectsBadIdentifiers() {
        let badIDs: [JSONValue] = [
            .string(""),
            .string(String(repeating: "x", count: 65)),
            .string("inst 1"),
            .number(7),
        ]
        for bad in badIDs {
            #expect(throws: BridgeFault.self) {
                try SurfaceEventDecoder.decode(method: ControlMethod.slotUnmount, payload: .object(["instanceId": bad]))
            }
        }
        #expect(!SurfaceEventDecoder.isValidSlotName("../etc/passwd"))
        #expect(!SurfaceEventDecoder.isValidSlotName(""))
        #expect(SurfaceEventDecoder.isValidSlotName("sidebar.workspaces"))
    }

    @Test("slot/rect 缺 scrollable 必须拒绝，不能默认 false")
    func rectRequiresScrollableFlag() {
        // 默认 false 会把「不知道」静默当成「安全」，那就是 ADR-0003 被绕过的方式。
        #expect(throws: BridgeFault.self) {
            try SurfaceEventDecoder.decode(method: ControlMethod.slotRect, payload: .object([
                "instanceId": .string("inst-1"),
                "rect": .object(["x": 0, "y": 0, "w": 100, "h": 40]),
            ]))
        }
    }

    @Test("荒谬几何被拒绝")
    func rejectsInsaneGeometry() {
        #expect(throws: BridgeFault.self) {
            try SurfaceEventDecoder.decode(method: ControlMethod.slotRect, payload: .object([
                "instanceId": .string("inst-1"),
                "rect": .object(["x": 0, "y": 0, "w": -5, "h": 9_999_999]),
                "scrollable": .bool(false),
            ]))
        }
        #expect(!SlotRect(x: .nan, y: 0, w: 1, h: 1).isSane)
        #expect(SlotRect(x: 12, y: 40, w: 260, h: 800).isSane)
    }

    @Test("props 键数 / 深度 / 键名越界被拒绝")
    func rejectsAbusiveProps() {
        var wide: [String: JSONValue] = [:]
        for index in 0..<(SurfaceInputLimits.maxPropKeys + 1) { wide["k\(index)"] = .bool(true) }
        #expect(throws: BridgeFault.self) {
            try SurfaceEventDecoder.decode(method: ControlMethod.slotProps, payload: .object([
                "instanceId": .string("inst-1"),
                "props": .object(wide),
            ]))
        }

        var deep = JSONValue.string("leaf")
        for _ in 0..<(SurfaceInputLimits.maxPropDepth + 2) { deep = .object(["nest": deep]) }
        #expect(throws: BridgeFault.self) {
            try SurfaceEventDecoder.decode(method: ControlMethod.slotProps, payload: .object([
                "instanceId": .string("inst-1"),
                "props": deep,
            ]))
        }

        #expect(throws: BridgeFault.self) {
            try SurfaceEventDecoder.decode(method: ControlMethod.slotProps, payload: .object([
                "instanceId": .string("inst-1"),
                "props": .object(["not a key": .bool(true)]),
            ]))
        }
    }

    @Test("未知控制方法回 unknown_method")
    func rejectsUnknownMethod() throws {
        do {
            _ = try SurfaceEventDecoder.decode(method: "slot/teleport", payload: .object([:]))
            Issue.record("expected a fault")
        } catch let fault as BridgeFault {
            #expect(fault.code == .unknownMethod)
        }
    }

    @Test("slot/error 必须带 abdicated 布尔")
    func decodesSlotError() throws {
        let event = try SurfaceEventDecoder.decode(method: ControlMethod.slotError, payload: .object([
            "slot": .string("sidebar.workspaces"),
            "instanceId": .string("inst-1"),
            "error": .string("boom"),
            "abdicated": .bool(true),
        ]))
        guard case .error(let report) = event else {
            Issue.record("expected error report")
            return
        }
        #expect(report.abdicated)
        #expect(report.instanceID == "inst-1")

        #expect(throws: BridgeFault.self) {
            try SurfaceEventDecoder.decode(method: ControlMethod.slotError, payload: .object([
                "slot": .string("sidebar.workspaces"),
                "error": .string("boom"),
            ]))
        }
    }

    @Test("surface/ready 解出协议版本与实测插槽表")
    func decodesReady() throws {
        let ready = try SurfaceEventDecoder.decodeReady(.object([
            "protocol": .number(1),
            "slots": .array([
                .object(["name": .string("sidebar.workspaces"), "kind": .string("single"), "scope": .string("root"), "owner": .string("ui-workspace"), "priority": .number(0)]),
                // 未知 kind 走兜底（kind 只用于诊断）。
                .object(["name": .string("sidebar.future"), "kind": .string("bag"), "scope": .string("session-maybe")]),
            ]),
        ]))
        #expect(ready.protocolVersion == 1)
        #expect(ready.slots.count == 2)
        #expect(ready.slots[0].kind == .single)
        #expect(ready.slots[0].owner == "ui-workspace")
        #expect(ready.slots[1].kind == .unknown("bag"))
        #expect(ready.slots[1].scope == .sessionMaybe)
    }

    @Test("surface/ready 缺 protocol 被拒绝")
    func readyRequiresProtocol() {
        #expect(throws: BridgeFault.self) {
            try SurfaceEventDecoder.decodeReady(.object(["slots": .array([])]))
        }
    }
}

@Suite("surface manifest 解析规则（surface-manifest.md §4）")
struct SurfaceManifestTests {
    @Test("规则 1：未列出的插槽 = web")
    func unlistedSlotsAreWeb() {
        let manifest = SurfaceManifest.w1Default
        #expect(manifest.entry(for: "sidebar.settings").mode == .web)
        #expect(manifest.entry(for: W1.workspacesSlot).mode == .native)
        // 上游新增插槽自动落到安全侧：这就是「不动官方 UI」的默认。
        #expect(manifest.entry(for: "sidebar.brandNewThing").mode == .web)
    }

    @Test("W1 出厂默认只接管 sidebar.workspaces，不接管父插槽")
    func w1DefaultOnlyTargetsWorkspaces() {
        #expect(SurfaceManifest.w1Default.slots.keys.sorted() == ["sidebar.workspaces"])
        // 遮蔽父 `sidebar` 就得继承它三个子插槽的声明责任（slot-map.md §3）。
        #expect(SurfaceManifest.w1Default.entry(for: "sidebar").mode == .web)
        #expect(SurfaceManifest.w1Default.entry(for: W1.workspacesSlot).placement == .evacuated)
        #expect(SurfaceManifest.w1Default.entry(for: W1.workspacesSlot).priority == -1)
    }

    @Test("规则 5：keys / ids 覆盖父级 mode")
    func keyedOverridesParent() {
        let manifest = SurfaceManifest(slots: [
            "tab.body": SlotEntry(mode: .native, keys: ["diff": SlotEntry(mode: .web)]),
            "sidebar.footer.action": SlotEntry(mode: .web, ids: ["studio.debug": SlotEntry(mode: .native)]),
        ])
        #expect(manifest.entry(for: "tab.body").mode == .native)
        #expect(manifest.entry(for: "tab.body", key: "diff").mode == .web)
        #expect(manifest.entry(for: "tab.body", key: "other").mode == .native)
        #expect(manifest.entry(for: "sidebar.footer.action", id: "studio.debug").mode == .native)
        #expect(manifest.entry(for: "sidebar.footer.action", id: "official.x").mode == .web)
    }

    @Test("mode 的两个语义位：是否装配 / 是否赢得渲染")
    func modeSemantics() {
        #expect(SlotMode.web.mountsNativeView == false)
        #expect(SlotMode.mirrored.mountsNativeView)
        #expect(SlotMode.mirrored.ownsRendering == false) // 装配但不渲染 = 对照
        #expect(SlotMode.native.ownsRendering)
        #expect(SlotMode.retired.ownsRendering)
        // 没有第五态：manifest 不能表达「谁都不渲染」（surface-manifest.md §7）。
        #expect(SlotMode.allCases.count == 4)
    }

    @Test("patch 是逐插槽整份替换")
    func patchReplacesPerSlot() {
        var patch = SurfaceManifest()
        patch.set(SlotEntry(mode: .web), for: W1.workspacesSlot)
        let applied = SurfaceManifest.w1Default.applying(patch: patch)
        #expect(applied.entry(for: W1.workspacesSlot).mode == .web)
        #expect(SurfaceManifest.w1Default.entry(for: W1.workspacesSlot).mode == .native) // 原值不变
    }

    @Test("entry 缺字段走默认值（web / evacuated / -1）")
    func decodesDefaults() throws {
        let entry = try JSONValue.object([:]).decoded(as: SlotEntry.self)
        #expect(entry.mode == .web)
        #expect(entry.placement == .evacuated)
        #expect(entry.priority == -1)
    }

    @Test("configure / reconfigure 载荷键名符合契约")
    func payloadShape() throws {
        let configure = try SurfaceManifest.w1Default.configurePayload
        #expect(configure["manifest"]?["sidebar.workspaces"]?["mode"]?.stringValue == "native")
        let reconfigure = try SurfaceManifest.w1Default.reconfigurePayload
        #expect(reconfigure["patch"]?["sidebar.workspaces"] != nil)
    }

    @Test("configure 回执解码：applied / rejected")
    func decodesConfigureResult() throws {
        let result = try ConfigureResult.decode(.object([
            "applied": .array([.string("sidebar.workspaces")]),
            "rejected": .array([.object(["slot": .string("sidebar"), "reason": .string("priority_conflict")])]),
        ]))
        #expect(result.applied == ["sidebar.workspaces"])
        #expect(result.rejected == [ConfigureResult.Rejection(slot: "sidebar", reason: "priority_conflict")])
    }
}
