import SwiftUI

/// 上游 `StateDot` 的原生复刻（`ui-primitives/src/StateDot.tsx` +
/// `StateDot.module.css`）。
///
/// 第一版这里是「一个 6px 的品牌色圆点」。那是**猜**出来的：上游 running 态根本
/// 不是圆点，而是一个 10×10 的像素追逐 —— 3×3 矩阵的 8 个外格按顺时针依次点亮，
/// 每格 2px、四级不透明度（1 / 0.6 / 0.35 / 0.15）、一圈 1 秒；颜色也不是
/// `state-business-primary`（deepseek-500），而是 deepseek-**450**，上游为此专门
/// 留了一条注释说明「这一步没有 alias token」。一颗静止的圆点和它并排，一眼就
/// 能看出是两套东西。
///
/// 非 running 的行**不画点**：上游 `showStatus = primaryStatus.state !== 'done'
/// || row.completed`，即空闲且未完成的行只留一个 16px 的空槽。我们的领域模型
/// 目前只有 `running`（`completed` 尚未接入），所以这里只实现 running 一种状态，
/// 其余留空 —— 少画一个点比画一个语义错误的点好。
struct SidebarStateDot: View {
    /// `.matrix` 的外径（figma 10px）。
    static let size: CGFloat = 10
    /// 一圈 8 格 × 125ms = 1s（上游 `animation: dsh-state-dot-chase 1s infinite`）。
    static let stepDuration: TimeInterval = 0.125

    /// `--dsw-static-deepseek-450: rgb(86, 134, 254)`。两套主题同值。
    private static let ongoing = Color(nsColor: NSColor(srgbRed: 86 / 255, green: 134 / 255, blue: 254 / 255, alpha: 1))

    /// 外圈 8 格在 10px 网格上的坐标（顺时针，从左上开始）。
    private static let cells: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 4),
        CGPoint(x: 8, y: 8), CGPoint(x: 4, y: 8), CGPoint(x: 0, y: 8), CGPoint(x: 0, y: 4),
    ]

    /// `@keyframes dsh-state-dot-chase` 的四级台阶（离当前头部越远越暗）。
    private static let trail: [Double] = [1, 0.6, 0.35, 0.15]

    var body: some View {
        // `TimelineView` 而不是 `withAnimation` + `@State`：这条动画是**离散**的
        // （上游用 flat keyframe hold 刻意做出复古的跳格感，没有插值），按时间片
        // 直接算出每格的不透明度比补间更接近原样，也不需要维护一个计时器状态。
        TimelineView(.periodic(from: .now, by: Self.stepDuration)) { context in
            let head = Int(context.date.timeIntervalSince1970 / Self.stepDuration) % Self.cells.count
            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.cells.enumerated()), id: \.offset) { index, cell in
                    Rectangle()
                        .fill(Self.ongoing)
                        .frame(width: 2, height: 2)
                        .opacity(Self.opacity(cell: index, head: head))
                        .offset(x: cell.x, y: cell.y)
                }
            }
            .frame(width: Self.size, height: Self.size, alignment: .topLeading)
        }
        .frame(width: Self.size, height: Self.size)
    }

    /// 距离头部 0/1/2/3 格分别是 1 / 0.6 / 0.35 / 0.15，更远一律 0.15。
    static func opacity(cell: Int, head: Int) -> Double {
        let distance = (head - cell + cells.count) % cells.count
        return distance < trail.count ? trail[distance] : trail[trail.count - 1]
    }
}
