import Testing
import CoreGraphics
@testable import DSHKit

/// CSS px → point 的换算是这次 W1 返工的核心：截图在这台机器上拿不到
/// （屏幕录制权限被拒），所以「原生栏有没有精确填进 Web 让出的格子」只能靠
/// 数值断言来证明。换算被刻意做成纯函数，就是为了让这些断言存在。
@Suite("SlotGeometryResolver：CSS px → point 的换算与裁剪（known-gaps.md G-1）")
struct SlotGeometryTests {
    /// 1440 CSS px 宽的视口 + 1440 point 宽的 WebView：比例 1，最常见的情况。
    private let viewport = SlotSize(w: 1_440, h: 900)
    private let webView = CGSize(width: 1_440, height: 900)

    @Test("比例 = WebView 点宽 / CSS 视口宽，而不是 devicePixelRatio")
    func scaleIgnoresDevicePixelRatio() {
        // Retina 上 dpr = 2，但 CSS px 和 point 是 1:1。把 dpr 当换算系数，
        // 原生栏会正好宽出一倍 —— 这是这类 bug 最经典的形态，钉死它。
        let geometry = SlotGeometry(
            rect: SlotRect(x: 0, y: 52, w: 260, h: 848),
            viewport: viewport,
            devicePixelRatio: 2
        )
        let placement = SlotGeometryResolver.resolve(geometry, webViewSize: webView)
        #expect(placement.scale == 1)
        #expect(placement.frame == CGRect(x: 0, y: 52, width: 260, height: 848))
    }

    @Test("页面缩放：视口宽与 WebView 点宽不等时，比例吸收掉差值")
    func scaleFollowsPageZoom() {
        // pageZoom = 1.25 → 同一块 WebView（1440 point）里只装得下 1152 CSS px。
        let geometry = SlotGeometry(
            rect: SlotRect(x: 0, y: 40, w: 208, h: 400),
            viewport: SlotSize(w: 1_152, h: 720)
        )
        let placement = SlotGeometryResolver.resolve(geometry, webViewSize: webView)
        #expect(abs(placement.scale - 1.25) < 0.000_1)
        #expect(abs(placement.frame.width - 260) < 0.001)
        #expect(abs(placement.frame.minY - 50) < 0.001)
    }

    @Test("视口缺失或比例荒谬时退回 1，而不是静默乘一个错系数")
    func scaleFallsBackToOne() {
        #expect(SlotGeometryResolver.scale(cssViewport: nil, webViewSize: webView) == 1)
        #expect(SlotGeometryResolver.scale(cssViewport: SlotSize(w: 0, h: 0), webViewSize: webView) == 1)
        // 1440 / 10 = 144，远在合理区间外：两侧对「视口」的理解已经不同了。
        #expect(SlotGeometryResolver.scale(cssViewport: SlotSize(w: 10, h: 10), webViewSize: webView) == 1)
    }

    @Test("裁剪祖先：frame 保持完整，visibleFrame 被裁到 clip")
    func clipShrinksVisibleFrameOnly() {
        // frame 必须保持完整，视图才会按「本该有的尺寸」布局；裁剪只影响画到
        // 哪里（mask）。反过来做（直接把 frame 裁小）会让内部布局跟着变形 ——
        // 折叠动画期间行高、字号都会抖。
        let geometry = SlotGeometry(
            rect: SlotRect(x: 0, y: 52, w: 260, h: 848),
            clip: SlotRect(x: 0, y: 52, w: 260, h: 500),
            viewport: viewport
        )
        let placement = SlotGeometryResolver.resolve(geometry, webViewSize: webView)
        #expect(placement.frame.height == 848)
        #expect(placement.visibleFrame == CGRect(x: 0, y: 52, width: 260, height: 500))
        #expect(placement.isRenderable)
    }

    @Test("WebView 边界是最后一个裁剪祖先")
    func webViewBoundsClipToo() {
        let geometry = SlotGeometry(
            rect: SlotRect(x: 1_300, y: 800, w: 400, h: 400),
            viewport: viewport
        )
        let placement = SlotGeometryResolver.resolve(geometry, webViewSize: webView)
        #expect(placement.visibleFrame == CGRect(x: 1_300, y: 800, width: 140, height: 100))
    }

    @Test("被完整遮挡 → 不渲染（Web 侧的浮层赢）")
    func occludedIsNotRenderable() {
        // 原生视图是 WKWebView 的兄弟/子视图，Web 的模态遮罩盖不住它。
        // 与其让一块点得到的原生控件浮在遮罩之上，不如让它退场。
        let geometry = SlotGeometry(
            rect: SlotRect(x: 0, y: 52, w: 260, h: 848),
            viewport: viewport,
            occluded: true
        )
        #expect(SlotGeometryResolver.resolve(geometry, webViewSize: webView).isRenderable == false)
    }

    @Test("裁到零面积 → 不渲染，且 visibleFrame 是 .zero 而不是 null 矩形")
    func fullyClippedIsNotRenderable() {
        // 侧栏折叠动画会把这个 cell 一路裁到 0 宽。`CGRect.null` 传进 SwiftUI 的
        // frame 会变成 NaN 布局警告，所以在这里就归一化。
        let geometry = SlotGeometry(
            rect: SlotRect(x: 0, y: 52, w: 260, h: 848),
            clip: SlotRect(x: 0, y: 52, w: 0, h: 848),
            viewport: viewport
        )
        let placement = SlotGeometryResolver.resolve(geometry, webViewSize: webView)
        #expect(placement.isRenderable == false)
        #expect(placement.visibleFrame == .zero)
    }

    @Test("clip 与 rect 完全错开（滚出视野）→ 不渲染")
    func disjointClipIsNotRenderable() {
        let geometry = SlotGeometry(
            rect: SlotRect(x: 0, y: 900, w: 260, h: 400),
            clip: SlotRect(x: 0, y: 0, w: 1_440, h: 900),
            viewport: viewport
        )
        #expect(SlotGeometryResolver.resolve(geometry, webViewSize: webView).isRenderable == false)
    }

    @Test("W1 实测数值：官方侧栏让出的格子被精确填满")
    func w1RealWorldNumbers() {
        // 这组数是 W1 现场量到的：AppFrame 的侧栏 track 宽 260 CSS px，
        // 标题栏高 52，底部还有 40 的 footer。返工前的截图里原生栏只有约
        // 150 高、并且整个 Web UI 被推到 x≈225 —— 那两个症状都必须在这组
        // 数值上不成立。
        let geometry = SlotGeometry(
            rect: SlotRect(x: 0, y: 52, w: 260, h: 808),
            clip: SlotRect(x: 0, y: 52, w: 260, h: 808),
            viewport: SlotSize(w: 1_440, h: 900),
            scrollable: false,
            occluded: false,
            devicePixelRatio: 2
        )
        let placement = SlotGeometryResolver.resolve(geometry, webViewSize: CGSize(width: 1_440, height: 900))
        #expect(placement.frame == CGRect(x: 0, y: 52, width: 260, height: 808))
        #expect(placement.visibleFrame == placement.frame)
        #expect(placement.isRenderable)
        // 关键：原生栏的左边界就是 0 —— Web UI 没有被右推，原生视图是**盖**在
        // 它自己那一格上的。
        #expect(placement.frame.minX == 0)
    }
}
