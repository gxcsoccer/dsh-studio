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

    @Test("W1 兜底 manifest 自身就满足规则 7（bottom-up），且不接管父插槽")
    func w1DefaultSatisfiesRuleSeven() {
        // 两行，不是一行：接管 `sidebar.workspaces` 就必须同时声明它的子槽，
        // 否则 client 半按规则 7 把这一行整条拒掉（known-gaps.md G-4 实测）。
        #expect(SurfaceManifest.w1Default.slots.keys.sorted() == [
            "sidebar.workspaces", "sidebar.workspaces.directoryFlow",
        ])
        #expect(SurfaceManifest.w1Default.entry(for: W1.workspacesDirectoryFlowSlot).mode == .retired)
        // 遮蔽父 `sidebar` 就得继承它三个子插槽的声明责任（slot-map.md §3）。
        #expect(SurfaceManifest.w1Default.entry(for: "sidebar").mode == .web)
        #expect(SurfaceManifest.w1Default.entry(for: W1.workspacesSlot).placement == .evacuated)
        #expect(SurfaceManifest.w1Default.entry(for: W1.workspacesSlot).priority == -1)
    }

    @Test("G-5：暗槽（被接管父槽下的子槽）不要求原生实现，但仍然是 native 语义")
    func darkHolesNeedNoNativeView() {
        let manifest = SurfaceManifest.w1Default
        // `directoryFlow` 的父槽赢下了 cell → 官方子树不挂载 → 这个 hole 永不渲染。
        #expect(manifest.isDarkHole(W1.workspacesDirectoryFlowSlot))
        #expect(manifest.isDarkHole(W1.workspacesSlot) == false)
        // 于是「宿主必须有 SwiftUI 实现」的只有一格。
        #expect(manifest.slotsRequiringNativeView == [W1.workspacesSlot])

        // 反面：父槽掰回 web（用户自救）之后，子槽就不再是暗槽 —— 官方子树会
        // 重新挂载并渲染这个 hole，谁接管它就得真有实现。
        var rolledBack = manifest
        rolledBack.set(SlotEntry(mode: .web), for: W1.workspacesSlot)
        #expect(rolledBack.isDarkHole(W1.workspacesDirectoryFlowSlot) == false)
        #expect(rolledBack.slotsRequiringNativeView == [W1.workspacesDirectoryFlowSlot])

        // mirrored 父槽不藏任何东西（它不赢 cell），所以不制造暗槽。
        var mirroredParent = manifest
        mirroredParent.set(SlotEntry(mode: .mirrored), for: W1.workspacesSlot)
        #expect(mirroredParent.isDarkHole(W1.workspacesDirectoryFlowSlot) == false)
    }

    @Test("G-5：retired 仍然装配原生视图（ARCHITECTURE.md §5：retired 由我们渲染）")
    func retiredStillMountsNativeView() {
        // retired 与 native 的差别只是意图，不是渲染行为。若这里是 false，
        // surface-manifest.md §3 里记成 `mode: retired` 的已完成插槽会变成空白。
        #expect(SlotMode.retired.mountsNativeView)
        #expect(SlotMode.retired.ownsRendering)
        let leaf = SurfaceManifest(slots: [W1.workspacesSlot: SlotEntry(mode: .retired)])
        #expect(leaf.slotsRequiringNativeView == [W1.workspacesSlot])
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

    /// G-7 的可执行形式：`single` 插槽的行**不能**带 `keys` / `ids`，哪怕是空表。
    ///
    /// client 半 `expandCells()` 对 `single` 插槽的判据是「存在即拒」
    /// （`entry.keys !== undefined || entry.ids !== undefined` → `bad_payload`），
    /// 不是「非空才拒」。Swift 的 `SlotEntry` 把 keys/ids 建模成非可选字典，
    /// 合成的 `encode(to:)` 于是把 `{}` 也写上线 —— W1 两行都是 `single`，
    /// 于是**两行全被拒**，宿主全拒降级回官方 Web UI（known-gaps.md G-7）。
    @Test("configure 载荷不带空 keys / ids（single 插槽会因此被整条拒绝）")
    func payloadOmitsEmptyChildTables() throws {
        let manifest = try SurfaceManifest.w1Default.configurePayload["manifest"]
        for slot in SurfaceManifest.w1Default.slots.keys {
            let row = try #require(manifest?[slot]?.objectValue)
            #expect(row["keys"] == nil, "\(slot) 带了 keys，client 会 bad_payload")
            #expect(row["ids"] == nil, "\(slot) 带了 ids，client 会 bad_payload")
        }
    }

    /// 有子表时必须照常上线（省略只针对空表）。
    @Test("keys / ids 非空时照常编码")
    func payloadKeepsNonEmptyChildTables() throws {
        var manifest = SurfaceManifest()
        manifest.set(
            SlotEntry(mode: .native, keys: ["main": SlotEntry(mode: .mirrored)]),
            for: "some.keyed.slot"
        )
        let row = try #require(manifest.configurePayload["manifest"]?["some.keyed.slot"])
        #expect(row["keys"]?["main"]?["mode"]?.stringValue == "mirrored")
        #expect(row.objectValue?["ids"] == nil)
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

/// G-7 的可执行形式：**两侧共读同一份字节**。
///
/// `contracts/w1-surface-configure.json` 由这里（生产者）与
/// `packages/studio-client/tests/manifest-golden.test.ts`（消费者）同时读取。
/// G-7 之所以两侧全绿却端到端全拒，就是因为两边各测自己手写的 fixture：
/// 一边测「我以为我编成这样」，一边测「我以为对面发这样」，中间差了个 `keys: {}`。
@Suite("wire golden：surface/configure 的线上字节（known-gaps.md G-7）")
struct WireGoldenTests {
    /// 仓库根目录 —— 从本文件位置回溯 `Tests/DSHKitTests` → `apps/macos` → 根。
    private static let goldenURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DSHKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .deletingLastPathComponent() // apps
        .deletingLastPathComponent() // <root>
        .appendingPathComponent("contracts/w1-surface-configure.json")

    @Test("w1Default 的 configure 载荷与 golden 逐字段一致")
    func payloadMatchesGolden() throws {
        let golden = try JSONValue.decode(Data(contentsOf: Self.goldenURL))
        let payload = try SurfaceManifest.w1Default.configurePayload
        #expect(payload == golden)
    }

    @Test("golden 自身不带 keys / ids：single 插槽上「存在即拒」")
    func goldenCarriesNoChildTables() throws {
        let golden = try JSONValue.decode(Data(contentsOf: Self.goldenURL))
        let rows = try #require(golden["manifest"]?.objectValue)
        #expect(rows.count == 2)
        for (slot, row) in rows {
            #expect(row.objectValue?["keys"] == nil, "\(slot) 带了 keys")
            #expect(row.objectValue?["ids"] == nil, "\(slot) 带了 ids")
        }
    }

    /// golden 必须是生产代码**实际产出**的字节，而不是手写出来「让测试过」的。
    @Test("golden 能反解回 w1Default")
    func goldenDecodesBackToModel() throws {
        let data = try Data(contentsOf: Self.goldenURL)
        let info = try RemoteSurfaceInfo.decode(data)
        #expect(info.manifest == SurfaceManifest.w1Default)
    }
}

/// G-4 的可执行形式：宿主读 runtime 那份 manifest，而不是自己编译一份。
@Suite("GET /studio/surface：权威 manifest 的线上形态（known-gaps.md G-4）")
struct RemoteSurfaceInfoTests {
    /// 真实响应体 —— 字段与 `studio-surface` 的 `SurfaceInfo` 一一对应，
    /// manifest 那份就是 `profiles/studio/cordis.patch.yml` 里的两行。
    private let body = Data("""
    {
      "protocol": 1,
      "manifest": {
        "sidebar.workspaces.directoryFlow": { "mode": "retired", "placement": "evacuated", "priority": -1 },
        "sidebar.workspaces": { "mode": "native", "placement": "evacuated", "priority": -1 }
      },
      "compareHotkey": "opt+shift+d",
      "census": { "web": 0, "mirrored": 0, "native": 1, "retired": 1 }
    }
    """.utf8)

    @Test("解析出的 manifest 与 profile 里那两行一致，并且规则 7 自洽")
    func decodesTheProfileManifest() throws {
        let info = try RemoteSurfaceInfo.decode(body)
        #expect(info.protocolVersion == 1)
        #expect(info.compareHotkey == "opt+shift+d")
        #expect(info.census["native"] == 1)
        #expect(info.manifest.slots.keys.sorted() == [
            "sidebar.workspaces", "sidebar.workspaces.directoryFlow",
        ])
        #expect(info.manifest.entry(for: W1.workspacesSlot).mode == .native)
        #expect(info.manifest.entry(for: W1.workspacesDirectoryFlowSlot).mode == .retired)
        // 宿主只需要为一格准备原生实现：另一格是暗槽（G-5）。
        #expect(info.manifest.slotsRequiringNativeView == [W1.workspacesSlot])
    }

    @Test("未知 mode 不兜底：宁可退回编译期 manifest，也不按半懂的表接管 UI")
    func rejectsUnknownMode() {
        let rogue = Data(#"{"protocol":1,"manifest":{"sidebar":{"mode":"hidden"}}}"#.utf8)
        #expect(throws: (any Error).self) { try RemoteSurfaceInfo.decode(rogue) }
    }

    @Test("没有 manifest 字段 = 不是这条路由的响应，报错而不是当空表")
    func rejectsMissingManifest() {
        #expect(throws: RemoteSurfaceInfoError.missingManifest) {
            try RemoteSurfaceInfo.decode(Data(#"{"protocol":1}"#.utf8))
        }
    }

    @Test("缺省字段走 schema 默认（surface-manifest.md §2）")
    func fillsRowDefaults() throws {
        let info = try RemoteSurfaceInfo.decode(Data(#"{"manifest":{"details":{"mode":"native"}}}"#.utf8))
        let entry = info.manifest.entry(for: "details")
        #expect(entry.mode == .native)
        #expect(entry.placement == .evacuated)
        #expect(entry.priority == -1)
        #expect(info.protocolVersion == nil)
    }
}
