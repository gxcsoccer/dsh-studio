import SwiftUI
import DSHKit
import DSHSurface

/// 原生插槽层 —— **与 WKWebView 同尺寸、同原点地盖在它上面**。
///
/// 这是 W1 几何问题的答案。之前这里是 `HSplitView { nativeRail; webPane }`：
/// 原生视图作为 WebView 的**兄弟列**，把官方 UI 整体右推了一列宽 —— 于是
/// 官方 logo/新会话/设置从 x≈225 开始，而原生列的宽度、高度、内边距全部由
/// SwiftUI 自己猜，跟官方侧栏那一格毫无关系。
///
/// 现在的关系是：
///
/// ```
/// ┌─ NSWindow ───────────────────────────────────────────┐
/// │ ┌ WKWebView（占满内容区，官方 UI 完整渲染）─────────┐ │
/// │ │ ┌ 官方 sidebar ─┐                                │ │
/// │ │ │ logo          │  官方 conversation              │ │
/// │ │ │ 新会话        │                                 │ │
/// │ │ │ ┌ slot rect ┐ │ ← Web 侧渲染等尺寸不可见占位     │ │
/// │ │ │ │▓ 原生视图 ▓│ │   原生视图按上报的 rect 精确填入 │ │
/// │ │ │ └───────────┘ │                                 │ │
/// │ │ │ 设置          │                                 │ │
/// │ │ └───────────────┘                                │ │
/// │ └──────────────────────────────────────────────────┘ │
/// └──────────────────────────────────────────────────────┘
/// ```
///
/// 三条不变量，缺一条就会漂移：
///
/// 1. **本层的 frame 恒等于 WebView 的 frame**（它是 WebView 的 `overlay`）。
///    于是「WebView 在窗口里的原点」在结构上就是 `(0,0)`，不需要换算 ——
///    少一次能算错的换算，就少一种漂移。
/// 2. **CSS px → point 的比例来自 `viewport 宽 / 本层宽`**，不是
///    `devicePixelRatio`（那是点→物理像素，与本换算无关）。
/// 3. **裁剪祖先由 Web 侧上报**（`geometry.clip`），本层据此 mask；被完整遮挡
///    时整块退场，让 Web 赢（known-gaps.md G-1）。
struct NativeSlotLayer: View {
    let slot: String
    let coordinator: SurfaceCoordinator
    let stage: SlotStage

    /// 控制通道处于 `suspect`（丢了一拍心跳、还没判死）时**灰化并禁用**：
    /// 这一段里 `slot/invoke` 很可能已经无效，让用户点得到却点不动比什么都糟
    /// （known-gaps.md G-3 的收尾要求）。
    private var suspect: Bool { coordinator.controlLinkHealth.isSuspect }

    var body: some View {
        GeometryReader { proxy in
            let mounted = stage.visibleInstance(of: slot)
            let geometry = mounted?.geometry
            let placement = geometry.map { SlotGeometryResolver.resolve($0, webViewSize: proxy.size) }
            ZStack(alignment: .topLeading) {
                // 握手完成前 / 降级后：一个原生插槽视图都不渲染，整块 UI 归官方
                // （bridge-contract.md §1.1、ADR-0004）。这里**不画占位**：在
                // WebView 之上画一块「正在加载」会遮住官方自己那份完全可用的侧栏。
                if coordinator.phase.rendersNativeSlots,
                   let mounted,
                   let placement,
                   placement.isRenderable {
                    PositionedSlot(placement: placement) {
                        mounted.view
                    }
                    .opacity(suspect ? 0.45 : 1)
                    .disabled(suspect)
                    .accessibilityHint(suspect ? "控制通道无响应，原生侧栏暂时不可操作" : "")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 几何这条链只能靠数值验证（截图权限拿不到，见 SlotSnapshotRenderer）：
            // 一行日志把 Web 上报的 rect/clip/viewport 与本层解出的 frame 摆在
            // 一起，任何一段错位都能当场读出来。默认关，`DSH_STUDIO_LOG_GEOMETRY=1`
            // 打开。
            .modifier(SlotGeometryLogModifier(
                slot: slot,
                instance: mounted.map {
                    SlotGeometryLog.MountedInstance(id: $0.id, placement: $0.instance.placement)
                },
                geometry: geometry,
                webViewSize: proxy.size,
                placement: placement
            ))
        }
        // 注意这里**没有**背景、也没有 `contentShape`：本层铺满整块 WebView，
        // 一旦它自己可命中，官方 UI 的每一次点击都会被这块透明玻璃吃掉。只有
        // 落位后的插槽视图那一小块参与命中测试。
    }
}

/// 把一个插槽视图放到 `frame`，再 mask 到 `visibleFrame`。
///
/// 两个矩形分开是刻意的：视图的**布局**必须按完整 rect 做（否则文字会按一个
/// 被裁短的宽度去换行，就是截图里「作区」「索会话」那种左侧被切掉的样子），
/// 而**呈现**才按裁剪祖先求交后的可见区域切。
private struct PositionedSlot<Content: View>: View {
    let placement: SlotFrame
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            // 精确落位：宽高来自 Web 让出的那一格，不是 SwiftUI 的理想尺寸。
            .frame(width: placement.frame.width, height: placement.frame.height, alignment: .topLeading)
            .offset(x: placement.frame.minX, y: placement.frame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask(alignment: .topLeading) { visibleMask }
    }

    private var visibleMask: some View {
        Rectangle()
            .frame(width: placement.visibleFrame.width, height: placement.visibleFrame.height)
            .offset(x: placement.visibleFrame.minX, y: placement.visibleFrame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
