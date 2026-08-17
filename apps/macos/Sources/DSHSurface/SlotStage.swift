import SwiftUI
import DSHKit

/// 原生插槽视图的舞台：`instanceId` → 已装配的视图。
///
/// DSHApp 通过 `NativeSlotLayer` 观察它。舞台只知道「哪个实例该在哪」，
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
        /// 最近一次 `slot/rect` 的几何（CSS px，视口坐标）。
        ///
        /// 只有「Web 侧让位、原生填格」的落位（overlay）才有值，且**这里存的是
        /// 未换算的原始几何** —— CSS px → point 的换算需要 WKWebView 的点尺寸，
        /// 而那个尺寸只有视图层知道（`NativeSlotLayer` 的 `GeometryReader`）。
        /// 舞台不猜它，也就不会存一份「差不多对」的 frame。
        public var geometry: SlotGeometry?

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

    func position(_ instanceID: String, to geometry: SlotGeometry) {
        guard var item = mounted[instanceID] else { return }
        item.geometry = geometry
        mounted[instanceID] = item
    }
}
