import SwiftUI
import DSHKit
import DSHSurface

/// 一个插槽在原生 chrome 里的出口。
///
/// evacuated 落位（ARCHITECTURE.md §4.1）：该插槽整块离开 Web 布局，在这里
/// 占真实屏幕面积；Web 侧渲染成零尺寸。没有坐标同步、没有滚动同步。
public struct NativeSlotOutlet: View {
    private let slot: String
    private let coordinator: SurfaceCoordinator
    private let stage: SlotStage
    private let placeholder: AnyView

    public init<Placeholder: View>(
        slot: String,
        coordinator: SurfaceCoordinator,
        stage: SlotStage,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.slot = slot
        self.coordinator = coordinator
        self.stage = stage
        self.placeholder = AnyView(placeholder())
    }

    public var body: some View {
        // 握手完成前 / 降级后：一个原生插槽视图都不渲染（bridge-contract.md §1.1）。
        if coordinator.phase.rendersNativeSlots, let mounted = stage.visibleInstance(of: slot) {
            mounted.view
        } else {
            placeholder
        }
    }
}
