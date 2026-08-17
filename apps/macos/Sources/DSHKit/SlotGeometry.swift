import Foundation
import CoreGraphics

/// `slot/rect` 的完整几何（bridge-contract.md §1.7）。
///
/// **这是 known-gaps.md G-1 的解法。** 原来的 `slot/rect` 只有 `{x,y,w,h}`，
/// 于是原生视图无法自证「我该被裁到多大、我现在该不该显示」：
///
/// - `clip` —— 祖先 `overflow` 裁剪链求交后的可见矩形。W1 的目标插槽正好住在
///   官方侧栏的 `.regionArea`（`overflow: hidden`）里，侧栏折叠时整列还会被
///   `AppFrame` 的 grid track 裁一遍；没有它，原生视图会在动画期间溢出到
///   会话区上面。
/// - `occluded` —— 该矩形是否被 Web 侧的浮层**完整**盖住（模态遮罩、菜单）。
///   盖住时原生视图退场，让 Web 赢：一个空洞比一块浮在遮罩之上、点得到的
///   原生控件诚实得多。
///
/// - `viewport` —— CSS 视口尺寸。宿主用它和 WKWebView 的**点**尺寸相除得到
///   CSS px → point 的比例，于是页面缩放（`pageZoom`）不需要宿主去问 WebKit，
///   也不需要把 `devicePixelRatio` 误当成换算系数（那是点→物理像素的比例，
///   与本换算无关，只留作日志）。
public struct SlotGeometry: Hashable, Sendable {
    /// 插槽矩形，CSS px，**视口坐标**（`getBoundingClientRect`，含祖先滚动）。
    public var rect: SlotRect
    /// 祖先裁剪链 ∩ 视口后的可见矩形，CSS px、同一坐标系。
    public var clip: SlotRect
    /// CSS 视口尺寸（`innerWidth/innerHeight`）。缺省时按比例 1 处理。
    public var viewport: SlotSize?
    /// ADR-0003 的判据：是否处在滚动容器内部。
    public var scrollable: Bool
    /// G-1：是否被 Web 侧内容完整遮挡。
    public var occluded: Bool
    /// 仅诊断：点 → 物理像素的比例。**不参与任何换算。**
    public var devicePixelRatio: Double?

    public init(
        rect: SlotRect,
        clip: SlotRect? = nil,
        viewport: SlotSize? = nil,
        scrollable: Bool = false,
        occluded: Bool = false,
        devicePixelRatio: Double? = nil
    ) {
        self.rect = rect
        // 老的 client 半只会发 rect：那就等于「没有裁剪祖先」，而不是「全裁掉」。
        self.clip = clip ?? rect
        self.viewport = viewport
        self.scrollable = scrollable
        self.occluded = occluded
        self.devicePixelRatio = devicePixelRatio
    }

    /// 不可信输入的合理性检查（两个矩形都要过 `SlotRect.isSane`）。
    public var isSane: Bool {
        rect.isSane && clip.isSane && (viewport.map(\.isSane) ?? true)
    }
}

/// CSS 视口尺寸。
public struct SlotSize: Hashable, Sendable, Codable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }

    public var isSane: Bool {
        w.isFinite && h.isFinite && w >= 0 && h >= 0 && w <= 1_000_000 && h <= 1_000_000
    }
}

/// 换算后的落位结果 —— **SwiftUI 侧唯一被允许拿来摆视图的东西**。
///
/// 坐标系是「WKWebView 自己的左上角原点、单位 point」。宿主把原生插槽层
/// 做成 WebView 的 `overlay`，两者的 frame 在布局上恒等，所以「WebView 在
/// 窗口里的原点偏移」这一项在**结构上**就是 0，不需要算 —— 少一次能算错的
/// 换算，就少一种漂移。
public struct SlotFrame: Hashable, Sendable {
    /// 插槽矩形（point，WebView 局部坐标）。
    public var frame: CGRect
    /// 裁剪后真正可见的矩形（point）。视图应被 mask 到这里。
    public var visibleFrame: CGRect
    /// CSS px → point 的比例（`pageZoom` 的可观测形式）。
    public var scale: Double
    /// 现在该不该渲染：被完整遮挡、或裁到零面积 → 不渲染。
    public var isRenderable: Bool

    public init(frame: CGRect, visibleFrame: CGRect, scale: Double, isRenderable: Bool) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isRenderable = isRenderable
    }
}

/// CSS px（视口坐标）→ point（WebView 局部坐标）的**纯函数**换算。
///
/// 纯函数是刻意的：几何 bug 只能靠数值断言发现，而截图在这台机器上拿不到
/// （屏幕录制权限被拒）。所以换算全部住在这里，由 `DSHKitTests` 钉住。
public enum SlotGeometryResolver {
    /// 比例的合理区间。越界说明两侧对「视口」的理解已经不同，按 1 处理并让
    /// 日志去说 —— 不是静默乘一个荒谬的系数。
    public static let scaleBounds: ClosedRange<Double> = 0.1...10

    /// 求解一个插槽的落位。
    /// - Parameters:
    ///   - geometry: client 半上报的几何（CSS px）。
    ///   - webViewSize: WKWebView 的点尺寸（= 原生插槽层的尺寸）。
    public static func resolve(_ geometry: SlotGeometry, webViewSize: CGSize) -> SlotFrame {
        let scale = self.scale(cssViewport: geometry.viewport, webViewSize: webViewSize)
        let frame = rect(geometry.rect, scale: scale)
        let clip = rect(geometry.clip, scale: scale)
        // 视口本身是最后一个裁剪祖先：WebView 之外的部分不许画。
        let bounds = CGRect(origin: .zero, size: webViewSize)
        let intersection = frame.intersection(clip).intersection(bounds)
        // 「不可见」在 CoreGraphics 里有两种形态：完全错开时是 `.null`，而被裁到
        // 零宽/零高（侧栏折叠动画的每一帧都会经过它）时是一个**面积为 0 的普通
        // 矩形**。两者都不该被画，也都不该原样交给 SwiftUI —— `.null` 的
        // origin 是 ±infinity，进 `frame(width:height:)` 会变成 NaN 布局警告。
        // 所以在这里一起归一成 `.zero`，让下游只需要看 `isRenderable`。
        let hasArea = !intersection.isNull && intersection.width > 0.5 && intersection.height > 0.5
        return SlotFrame(
            frame: frame,
            visibleFrame: hasArea ? intersection : .zero,
            scale: scale,
            isRenderable: hasArea && !geometry.occluded
        )
    }

    /// CSS px → point 的比例。
    ///
    /// `webViewPointWidth / cssViewportWidth`：`pageZoom`、`<meta viewport>`
    /// 缩放、以及未来任何让两者不等的机制都被这一个比值吸收。宽度缺失或越界
    /// 时退回 1。
    public static func scale(cssViewport: SlotSize?, webViewSize: CGSize) -> Double {
        guard let cssViewport, cssViewport.w > 0, webViewSize.width > 0 else { return 1 }
        let ratio = Double(webViewSize.width) / cssViewport.w
        guard ratio.isFinite, scaleBounds.contains(ratio) else { return 1 }
        return ratio
    }

    private static func rect(_ rect: SlotRect, scale: Double) -> CGRect {
        CGRect(
            x: rect.x * scale,
            y: rect.y * scale,
            width: rect.w * scale,
            height: rect.h * scale
        )
    }
}
