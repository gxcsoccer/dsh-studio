import Foundation
import DSHKit

/// 编排 props 的白名单 —— **ADR-0002 在原生侧的执行点**。
///
/// 与 Web 侧 `serializeOrchestration` 的白名单同源
/// （reference/native-slot-proxy.md §1）。两侧都用白名单而不是黑名单：
/// 黑名单会在几十次插槽迁移里被一点点掏空。
///
/// 白名单外的 key 一律**丢弃并上报**，不是「先用着」——
/// 一次「就这一个字段先走 postMessage 吧」的妥协，就是终局重写的开始。
public enum OrchestrationProps {
    public static let allowed: Set<String> = [
        "collapsed", "selected", "expanded", "width", "disabled",
        "placeholder", "variant", "order", "label",
    ]

    /// 拆成「允许过桥的」与「违规的领域字段」两半。
    public static func split(_ patch: [String: JSONValue]) -> (kept: [String: JSONValue], rejected: [String]) {
        var kept: [String: JSONValue] = [:]
        var rejected: [String] = []
        for (key, value) in patch {
            if allowed.contains(key) {
                kept[key] = value
            } else {
                rejected.append(key)
            }
        }
        return (kept, rejected.sorted())
    }
}

/// 一个插槽实例的编排状态（**不含领域数据**）。
public struct SlotProps: Hashable, Sendable {
    public private(set) var storage: [String: JSONValue]

    public init(_ storage: [String: JSONValue] = [:]) {
        self.storage = storage
    }

    public subscript(key: String) -> JSONValue? { storage[key] }

    public var collapsed: Bool { storage["collapsed"]?.boolValue ?? false }
    public var expanded: Bool { storage["expanded"]?.boolValue ?? true }
    public var disabled: Bool { storage["disabled"]?.boolValue ?? false }
    /// 当前选中项的 id（编排状态：谁高亮，不是会话内容）。
    public var selected: String? { storage["selected"]?.stringValue }
    public var width: Double? { storage["width"]?.doubleValue }
    public var label: String? { storage["label"]?.stringValue }
    public var variant: String? { storage["variant"]?.stringValue }
    public var order: Int? { storage["order"]?.intValue }

    /// 浅 merge：Web 侧只发变化字段（bridge-contract.md §1.3）。
    /// `null` 表示删除该字段。
    mutating func merge(_ patch: [String: JSONValue]) {
        for (key, value) in patch {
            if value.isNull {
                storage.removeValue(forKey: key)
            } else {
                storage[key] = value
            }
        }
    }
}

/// `slot/invoke` 的出口。
@MainActor
public protocol SlotInvocationSink: AnyObject {
    @discardableResult
    func invoke(slot: String, instanceID: String, action: String, args: [JSONValue]) async throws -> JSONValue
}

/// 一个活着的插槽实例。
///
/// 原生视图与 `instanceId` **一一对应**，不与 slot 名对应
/// （bridge-contract.md §1.4）：`keyed` / `list` 插槽会同时存在多个实例。
@MainActor
@Observable
public final class SlotInstance: Identifiable {
    public let slot: String
    public let id: String
    /// `keyed` 插槽的 key。
    public let key: String?
    public let scope: SlotScope
    public let placement: Placement
    public let mode: SlotMode

    /// 编排 props（会随 `slot/props` 变化，视图应该观察它）。
    public private(set) var props: SlotProps
    /// 该实例暴露的注入面动作名（reference/native-slot-proxy.md §2）。
    public private(set) var actions: [String]
    /// `unmount` 之后为 false；视图不该再发 invoke。
    public private(set) var isLive = true
    /// 最近一次 invoke 的失败（UI 可以据此提示，而不是静默失效）。
    public private(set) var lastInvokeFailure: String?

    @ObservationIgnored
    private let invoker: (@MainActor (SlotInstance, String, [JSONValue]) async throws -> JSONValue)?

    init(
        mount: SlotMount,
        placement: Placement,
        mode: SlotMode,
        invoker: (@MainActor (SlotInstance, String, [JSONValue]) async throws -> JSONValue)?
    ) {
        slot = mount.slot
        id = mount.instanceID
        key = mount.key
        scope = mount.scope
        self.placement = placement
        self.mode = mode
        props = SlotProps(mount.props)
        actions = mount.actions
        self.invoker = invoker
    }

    /// 是否支持某个注入面动作 —— UI 据此决定显示哪些控件。
    public func can(_ action: String) -> Bool {
        actions.contains(action)
    }

    /// 调 Web 侧注入面（只转发动作与参数，不搬运数据）。
    @discardableResult
    public func invoke(_ action: String, _ args: [JSONValue] = []) async throws -> JSONValue {
        guard let invoker else { throw SurfaceError.slotNotMounted(instanceID: id) }
        guard isLive else { throw SurfaceError.slotNotMounted(instanceID: id) }
        do {
            let result = try await invoker(self, action, args)
            lastInvokeFailure = nil
            return result
        } catch {
            lastInvokeFailure = String(describing: error)
            throw error
        }
    }

    /// SwiftUI 按钮里的即发即忘版本。
    public func invokeDetached(_ action: String, _ args: [JSONValue] = []) {
        Task { @MainActor [weak self] in
            _ = try? await self?.invoke(action, args)
        }
    }

    func applyProps(_ patch: [String: JSONValue]) {
        props.merge(patch)
    }

    func replaceActions(_ next: [String]) {
        actions = next
    }

    func retire() {
        isLive = false
    }
}
