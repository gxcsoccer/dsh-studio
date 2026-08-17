import SwiftUI
import OSLog
import DSHKit

/// 运行时几何日志 —— **P3 的证据通道**。
///
/// 这一格的正确性是纯数值的：Web 侧让出多大一块（`rect`）、裁剪祖先剩下多少
/// （`clip`）、CSS 视口多宽（`viewport`）、WKWebView 多宽（点），以及本层解出的
/// `frame` / `visibleFrame`。任何一段错位都表现为同一个症状（原生栏偏了、矮了、
/// 文字被切了），肉眼分不出是哪一段错。所以把整条链打成**一行**，用等号连起来，
/// 让人一眼读出「哪个数不对」。
///
/// 默认关闭：这些行在窗口 resize 时会按帧刷屏。`DSH_STUDIO_LOG_GEOMETRY=1`
/// 打开（`scripts/dogfood.sh` 前面加这个变量即可）。
enum SlotGeometryLog {
    static let isEnabled = ProcessInfo.processInfo.environment["DSH_STUDIO_LOG_GEOMETRY"] == "1"

    private static let logger = Logger(subsystem: "com.dsh.studio", category: "geometry")

    /// 打一行。`geometry == nil` 表示这一格还没上报过几何。
    static func record(
        slot: String,
        instance: MountedInstance?,
        geometry: SlotGeometry?,
        webViewSize: CGSize,
        placement: SlotFrame?
    ) {
        guard isEnabled else { return }
        let line = describe(
            slot: slot,
            instance: instance,
            geometry: geometry,
            webViewSize: webViewSize,
            placement: placement
        )
        logger.notice("\(line, privacy: .public)")
        // 同时走 stdout：`dogfood.sh` 直接 exec 二进制，stdout 就是开发者的终端，
        // 不必再去 `log stream` 里捞。
        print(line)
        fflush(stdout)
    }

    /// 舞台上那一格的身份 —— 只取日志需要的两个字段。
    ///
    /// 单独拎出来是因为「没挂上」和「挂上了但没几何」是**两种完全不同的故障**，
    /// 而第一版日志把它们打成同一行 `rect=<unmounted>`：真实故障是 profile 里
    /// 写了 `placement: evacuated`（挂上了，永不上报 rect），却被读成了「Web 侧
    /// 根本没 mount」，白查了一轮。
    struct MountedInstance: Equatable {
        let id: String
        let placement: Placement
    }

    /// 纯函数的格式化（可被单测钉住，不需要跑 UI）。
    static func describe(
        slot: String,
        instance: MountedInstance?,
        geometry: SlotGeometry?,
        webViewSize: CGSize,
        placement: SlotFrame?
    ) -> String {
        var parts = ["[slot-geometry] \(slot)", "webView=\(size(webViewSize))"]
        if let instance {
            parts.append("instance=\(instance.id)")
            parts.append("placement=\(instance.placement.rawValue)")
        } else {
            parts.append("instance=<none>")
        }
        if let geometry {
            parts.append("rect=\(rect(geometry.rect))")
            parts.append("clip=\(rect(geometry.clip))")
            parts.append("viewport=\(geometry.viewport.map { "\(number($0.w))x\(number($0.h))" } ?? "-")")
            parts.append("scrollable=\(geometry.scrollable)")
            parts.append("occluded=\(geometry.occluded)")
            parts.append("dpr=\(geometry.devicePixelRatio.map(number) ?? "-")")
        } else {
            parts.append("rect=<none>")
        }
        if let placement {
            parts.append("scale=\(number(placement.scale))")
            parts.append("frame=\(cgRect(placement.frame))")
            parts.append("visibleFrame=\(cgRect(placement.visibleFrame))")
            parts.append("renderable=\(placement.isRenderable)")
        }
        return parts.joined(separator: " ")
    }

    private static func rect(_ rect: SlotRect) -> String {
        "(\(number(rect.x)),\(number(rect.y)),\(number(rect.w))x\(number(rect.h)))"
    }

    private static func cgRect(_ rect: CGRect) -> String {
        "(\(number(rect.minX)),\(number(rect.minY)),\(number(rect.width))x\(number(rect.height)))"
    }

    private static func size(_ size: CGSize) -> String {
        "\(number(size.width))x\(number(size.height))"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func number(_ value: CGFloat) -> String { number(Double(value)) }
}

/// 把日志挂到几何**变化**上，而不是每次 body 求值。
///
/// 用 `onChange(initial: true)` 而不是在 `body` 里直接 `print`：body 会因为任何
/// 无关的状态变化被重算，那样的日志既刷屏又会掩盖真正的几何变化。
struct SlotGeometryLogModifier: ViewModifier {
    let slot: String
    let instance: SlotGeometryLog.MountedInstance?
    let geometry: SlotGeometry?
    let webViewSize: CGSize
    let placement: SlotFrame?

    /// 变化判据：舞台上的实例 + Web 上报的几何 + WebView 尺寸。都不动就没什么可说的。
    private struct Key: Equatable {
        let instance: SlotGeometryLog.MountedInstance?
        let geometry: SlotGeometry?
        let size: CGSize
    }

    func body(content: Content) -> some View {
        content.onChange(of: Key(instance: instance, geometry: geometry, size: webViewSize), initial: true) { _, _ in
            SlotGeometryLog.record(
                slot: slot,
                instance: instance,
                geometry: geometry,
                webViewSize: webViewSize,
                placement: placement
            )
        }
    }
}
