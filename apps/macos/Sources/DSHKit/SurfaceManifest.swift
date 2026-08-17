import Foundation

/// 单个插槽的状态条目（surface-manifest.md §2）。
public struct SlotEntry: Hashable, Sendable, Codable {
    public var mode: SlotMode
    public var placement: Placement
    /// 遮蔽用 priority；官方默认 0，我们默认 -1。
    public var priority: Int
    /// 仅 `keyed` 插槽：按 key 分别配置。
    public var keys: [String: SlotEntry]
    /// 仅 `list` 插槽：按注册 id 分别配置。
    public var ids: [String: SlotEntry]

    public init(
        mode: SlotMode = .web,
        placement: Placement = .evacuated,
        priority: Int = -1,
        keys: [String: SlotEntry] = [:],
        ids: [String: SlotEntry] = [:]
    ) {
        self.mode = mode
        self.placement = placement
        self.priority = priority
        self.keys = keys
        self.ids = ids
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 未给的字段走默认值（surface-manifest.md §2 的 Schemastery 默认）。
        mode = try container.decodeIfPresent(SlotMode.self, forKey: .mode) ?? .web
        placement = try container.decodeIfPresent(Placement.self, forKey: .placement) ?? .evacuated
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? -1
        keys = try container.decodeIfPresent([String: SlotEntry].self, forKey: .keys) ?? [:]
        ids = try container.decodeIfPresent([String: SlotEntry].self, forKey: .ids) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case mode, placement, priority, keys, ids
    }

    /// **空的 `keys` / `ids` 必须不出现在线上**（known-gaps.md G-7）。
    ///
    /// 这里不是「省点字节」的洁癖，是契约：client 半对 `single` 插槽的判据是
    /// *存在即拒*（`expandCells()`：`entry.keys !== undefined ||
    /// entry.ids !== undefined` → `bad_payload`），因为在一个 `single` 插槽上
    /// 谈 key/id 本身就说明发送方把插槽种类搞错了 —— 这种错必须响。
    ///
    /// 而 Swift 这侧把 keys/ids 建模成**非可选**字典（读取端好写：`parent.keys[key]`
    /// 不用解包），合成的 `encode(to:)` 于是把 `{}` 也写上线。W1 那两行都是
    /// `single`，结果两行全被拒 → 宿主全拒降级，用户看到的是「原生插槽一个都没
    /// 出现」。所以模型的默认值不能直接当成线上的存在性：空表 = 没这张表。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(placement, forKey: .placement)
        try container.encode(priority, forKey: .priority)
        if !keys.isEmpty { try container.encode(keys, forKey: .keys) }
        if !ids.isEmpty { try container.encode(ids, forKey: .ids) }
    }
}

/// surface manifest：一张「插槽 → 状态」的表（surface-manifest.md）。
///
/// 解析规则（§4）在 `entry(for:key:id:)` 里实现：
///   1. 未列出的插槽 = `web`（默认不动官方 UI）
///   5. `keys` / `ids` 覆盖父级 mode，父级作为未列出 key/id 的默认
public struct SurfaceManifest: Hashable, Sendable, Codable {
    public var slots: [String: SlotEntry]

    public init(slots: [String: SlotEntry] = [:]) {
        self.slots = slots
    }

    public static let empty = SurfaceManifest()

    /// 规则 1：未列出 = `web`。上游新增插槽自动落到安全侧。
    public func entry(for slot: String, key: String? = nil, id: String? = nil) -> SlotEntry {
        guard let parent = slots[slot] else { return SlotEntry(mode: .web) }
        if let key, let child = parent.keys[key] {
            return merged(parent: parent, child: child)
        }
        if let id, let child = parent.ids[id] {
            return merged(parent: parent, child: child)
        }
        return parent
    }

    /// 规则 5：子条目覆盖 mode / placement，其余继承父级。
    private func merged(parent: SlotEntry, child: SlotEntry) -> SlotEntry {
        SlotEntry(
            mode: child.mode,
            placement: child.placement,
            priority: child.priority,
            keys: child.keys,
            ids: child.ids
        )
    }

    public mutating func set(_ entry: SlotEntry, for slot: String) {
        slots[slot] = entry
    }

    // MARK: 暗槽（dark hole）—— 规则 7 的另一面

    /// 该插槽是否是**暗槽**：它自己声明了要接管，但它的某个祖先插槽已经被
    /// Studio 接管，于是官方那棵 React 子树不再挂载，它内部的 `renderSlot()`
    /// **永不执行** —— 这一格永远不会有 `slot/mount` 到达宿主。
    ///
    /// 这不是我们发明的推论，是 surface-manifest.md §4 第 7 条的字面理由：
    /// 「原生父视图赢下 cell 后，官方那棵 React 子树不再挂载，于是它内部的
    /// `renderSlot()` 永不执行」。规则 7 因此要求 bottom-up：父槽要 native，
    /// 子槽必须先归 Studio。于是**每一个被接管的父槽都会在 manifest 里带上
    /// 一批纯记账的子槽行** —— 它们是「声明」而不是「实现」。
    ///
    /// 祖先关系用插槽名的点号层级判断，这正是上游插槽名的构造方式
    /// （`sidebar.workspaces.directoryFlow` 是 `sidebar.workspaces` 的子槽）。
    public func isDarkHole(_ slot: String) -> Bool {
        var prefix = slot
        while let dot = prefix.lastIndex(of: ".") {
            prefix = String(prefix[prefix.startIndex..<dot])
            if let ancestor = slots[prefix], ancestor.mode.ownsRendering { return true }
        }
        return false
    }

    /// 真正需要一份原生实现的插槽：要装配视图、且不是暗槽。
    ///
    /// 这是「宿主必须有 SwiftUI 实现」与「宿主必须关心契约漂移」的唯一口径
    /// （启动自检、漂移检测、全拒降级三处共用它，避免三处各算一遍算歪）。
    public var slotsRequiringNativeView: [String] {
        slots
            .filter { $0.value.mode.mountsNativeView && !isDarkHole($0.key) }
            .keys
            .sorted()
    }

    /// `surface/reconfigure` 的 patch 语义：逐插槽整份替换（surface-manifest.md §5）。
    public func applying(patch: SurfaceManifest) -> SurfaceManifest {
        var result = self
        for (slot, entry) in patch.slots {
            result.slots[slot] = entry
        }
        return result
    }

    public var configurePayload: JSONValue {
        get throws { .object(["manifest": try JSONValue(encoding: slots)]) }
    }

    public var reconfigurePayload: JSONValue {
        get throws { .object(["patch": try JSONValue(encoding: slots)]) }
    }
}

/// `surface/configure` 的回执（bridge-contract.md §1.1）。
public struct ConfigureResult: Hashable, Sendable {
    public struct Rejection: Hashable, Sendable {
        public let slot: String
        public let reason: String
        /// client 半给的人类可读原因。**必须一路带到日志**：`reason` 是那 7 个
        /// 封闭码之一（`bad_payload` 涵盖了从「键名拼错」到「规则 7 没满足」的
        /// 一切），只看它等于知道「有错」而不知道错在哪 —— G-7 就是因为宿主只
        /// 打印了 `slot: reason`，白白多花了一轮端到端排查。
        public let detail: String?

        public init(slot: String, reason: String, detail: String? = nil) {
            self.slot = slot
            self.reason = reason
            self.detail = detail
        }

        /// 日志形态：有 detail 就带上。
        public var logLine: String {
            guard let detail, !detail.isEmpty else { return "\(slot): \(reason)" }
            return "\(slot): \(reason) — \(detail)"
        }
    }

    public let applied: [String]
    public let rejected: [Rejection]

    public init(applied: [String], rejected: [Rejection]) {
        self.applied = applied
        self.rejected = rejected
    }

    public static func decode(_ payload: JSONValue) throws -> ConfigureResult {
        let applied = (payload["applied"]?.arrayValue ?? []).compactMap(\.stringValue)
        let rejected = (payload["rejected"]?.arrayValue ?? []).compactMap { value -> Rejection? in
            guard let slot = value["slot"]?.stringValue else { return nil }
            return Rejection(
                slot: slot,
                reason: value["reason"]?.stringValue ?? "unspecified",
                detail: value["detail"]?.stringValue
            )
        }
        return ConfigureResult(applied: applied, rejected: rejected)
    }
}

// MARK: - runtime 侧的权威 manifest（G-4）

/// `GET /studio/surface` 的响应（`studio-surface` 的 `SurfaceInfo`）。
///
/// **为什么宿主要读它**：surface-manifest.md §1 规定 manifest 只住在
/// `studio-surface` 那一行的 `config` 里 —— 热回滚、对照运行、用户自决
/// （§6 的配置分层）全靠这一点。编译进 Swift 的那份只能是「拿不到时的兜底」，
/// 否则同一张表有两个真相源，而两边一旦不一致，用户看到的是「配置被整条拒绝
/// 然后回落官方 UI」这种最难诊断的症状（known-gaps.md G-4 就是这么发现的）。
public struct RemoteSurfaceInfo: Hashable, Sendable {
    /// client 半宣称的控制通道协议版本。
    public let protocolVersion: Int?
    public let manifest: SurfaceManifest
    /// 把聚焦插槽掰回官方实现的热键（surface-manifest.md §5）。
    public let compareHotkey: String?
    /// 迁移记账（每个 mode 各几行）。
    public let census: [String: Int]

    public init(
        protocolVersion: Int? = nil,
        manifest: SurfaceManifest,
        compareHotkey: String? = nil,
        census: [String: Int] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.manifest = manifest
        self.compareHotkey = compareHotkey
        self.census = census
    }

    private struct Wire: Decodable {
        let `protocol`: Int?
        let manifest: [String: SlotEntry]?
        let compareHotkey: String?
        let census: [String: Int]?
    }

    /// 解析 `/studio/surface` 的响应体。
    ///
    /// 不做任何兜底猜测：`mode` 是封闭枚举，出现未知值就抛 —— 宿主宁可退回
    /// 编译期兜底 manifest，也不要按「差不多对」的表去接管 UI。
    public static func decode(_ data: Data) throws -> RemoteSurfaceInfo {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard let slots = wire.manifest else {
            throw RemoteSurfaceInfoError.missingManifest
        }
        return RemoteSurfaceInfo(
            protocolVersion: wire.protocol,
            manifest: SurfaceManifest(slots: slots),
            compareHotkey: wire.compareHotkey,
            census: wire.census ?? [:]
        )
    }
}

public enum RemoteSurfaceInfoError: Error, Hashable, Sendable, CustomStringConvertible {
    case missingManifest

    public var description: String {
        switch self {
        case .missingManifest: "GET /studio/surface answered without a `manifest` object"
        }
    }
}

// MARK: - W1 兜底 manifest

extension SurfaceManifest {
    /// W1 的**兜底** manifest（不是权威那份 —— 权威在 runtime 的
    /// `/studio/surface`，见 `RemoteSurfaceInfo`）。
    ///
    /// 只在拿不到 runtime 那份时使用（runtime 未起、token 失效、路由 404）。
    /// 即便如此它也必须**自身合法**：规则 7 是 bottom-up 的，所以接管
    /// `sidebar.workspaces` 就必须同时声明它的子槽
    /// `sidebar.workspaces.directoryFlow`，否则 client 半会把这一行整条拒绝
    /// （known-gaps.md G-4 实测过）。子槽记 `retired`：原生工作区视图自带
    /// macOS 目录选择器，官方那个对话框在本产品里不再有意义。
    ///
    /// 子槽是**暗槽**（`isDarkHole`）：父槽赢下 cell 之后它永不被渲染，所以
    /// 宿主不需要、也不该为它准备原生实现（known-gaps.md G-5）。
    ///
    /// 仍然不遮蔽 `sidebar` 本身 —— 遮蔽它就得继承它三个子插槽的声明责任
    /// （slot-map.md §3 的坑），第一刀不该那么深。
    public static let w1Default = SurfaceManifest(slots: [
        W1.workspacesSlot: SlotEntry(mode: .native, placement: .evacuated, priority: -1),
        W1.workspacesDirectoryFlowSlot: SlotEntry(mode: .retired, placement: .evacuated, priority: -1),
    ])
}
