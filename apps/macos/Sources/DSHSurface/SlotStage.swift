import SwiftUI
import DSHKit

/// 原生插槽视图的舞台：`instanceId` → 已装配的视图。
///
/// DSHApp 通过 `NativeSlotOutlet` 观察它。舞台只知道「哪个实例该在哪」，
/// 不知道视图内部在渲染什么。
@MainActor
@Observable
public final class SlotStage {
    /// 视图当前的呈现方式。
    public enum Presentation: Hashable, Sendable {
        /// 正常渲染（`native` / `retired`）。
        case visible
        /// `mirrored`：隐藏运行，仅用于对照（surface-manifest.md §4 规则 3）。
        case offscreenComparison
    }

    public struct Mounted: Identifiable {
        public let instance: SlotInstance
        public let view: AnyView
        public var presentation: Presentation
        /// 仅 overlay 落位有值。
        public var frame: CGRect?

        public var id: String { instance.id }
        public var slot: String { instance.slot }
    }

    public private(set) var mounted: [String: Mounted] = [:]

    public init() {}

    /// 某个插槽当前的所有实例（`list` / `keyed` 会有多个）。
    public func instances(of slot: String) -> [Mounted] {
        mounted.values
            .filter { $0.slot == slot }
            .sorted { ($0.instance.props.order ?? 0, $0.id) < ($1.instance.props.order ?? 0, $1.id) }
    }

    /// 某个插槽当前该渲染的实例（`single` 插槽用这个）。
    public func visibleInstance(of slot: String) -> Mounted? {
        instances(of: slot).first { $0.presentation == .visible }
    }

    func insert(_ item: Mounted) {
        mounted[item.id] = item
    }

    func remove(_ instanceID: String) {
        mounted.removeValue(forKey: instanceID)
    }

    func position(_ instanceID: String, to rect: SlotRect) {
        guard var item = mounted[instanceID] else { return }
        item.frame = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        mounted[instanceID] = item
    }
}
