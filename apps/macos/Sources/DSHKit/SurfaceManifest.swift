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

        public init(slot: String, reason: String) {
            self.slot = slot
            self.reason = reason
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
            return Rejection(slot: slot, reason: value["reason"]?.stringValue ?? "unspecified")
        }
        return ConfigureResult(applied: applied, rejected: rejected)
    }
}

// MARK: - W1 默认 manifest

extension SurfaceManifest {
    /// W1 出厂默认：只遮蔽 `sidebar.workspaces`（slot-map.md §3 的 (b) 路线）。
    ///
    /// 不遮蔽 `sidebar` 本身 —— 遮蔽它就得继承它三个子插槽的声明责任
    /// （slot-map.md §3 的坑），第一刀不该那么深。
    public static let w1Default = SurfaceManifest(slots: [
        W1.workspacesSlot: SlotEntry(mode: .native, placement: .evacuated, priority: -1),
    ])
}
