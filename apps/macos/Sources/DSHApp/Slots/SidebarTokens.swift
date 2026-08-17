import SwiftUI

/// 官方设计语言在 SwiftUI 侧的**唯一副本**。
///
/// W1 的第一版侧栏用的是 SwiftUI 默认值（`.headline`、`.roundedBorder`、
/// `List(.sidebar)`），结果是同一条侧栏里两种设计语言拼在一起，用户的判词是
/// 「很丑，没和 web 对齐」。原生化不是「换成原生控件」，是**在原生里复刻同一套
/// 设计语言**，直到用户看不出接缝为止。
///
/// 所以这些值不是「挑得差不多的颜色」，每一个都抄自上游 CSS：
///
/// - 颜色：`ui-theme/src/styles/design-platform.css` 的 `--dsw-*` 变量。
///   light / dark 两套都抄，用 `NSColor(name:dynamicProvider:)` 绑到系统外观 ——
///   上游主题偏好默认是 `system`（`ui-theme/src/client/index.ts` 用
///   `prefers-color-scheme` 解析），所以跟随系统就是跟随它。
/// - 尺寸：`ui-sidebar/src/client/SidebarRoot.module.css`、
///   `ui-workspace/src/client/WorkspaceBrowser.module.css`、
///   `ui-workspace/src/client/rows/Rows.module.css`。
///
/// 每个 token 都注掉它的来源变量名/类名：下次上游改版时，这份副本要能被一条
/// `grep` 追回原处，而不是靠猜。
enum SidebarTokens {
    // MARK: 颜色（design-platform.css）

    /// `--dsw-specific-sidebar-fill`：侧栏底色。
    static let sidebarFill = dynamic(light: rgb(249, 250, 251), dark: rgb(27, 27, 28))
    /// `--dsw-alias-label-primary`：正文（会话名、工作区名）。
    static let labelPrimary = dynamic(light: rgb(15, 17, 21), dark: rgb(249, 250, 251))
    /// `--dsw-alias-label-secondary`：次级（图标按钮）。
    static let labelSecondary = dynamic(light: rgb(97, 102, 107), dark: rgb(207, 211, 214))
    /// `--dsw-alias-label-tertiary`：三级（分组标题、时间、状态槽）。
    static let labelTertiary = dynamic(light: rgb(129, 133, 140), dark: rgb(173, 178, 184))
    /// `--dsw-alias-label-caption`：展开态搜索框的文字色。
    static let labelCaption = dynamic(light: rgb(173, 178, 184), dark: rgb(129, 133, 140))
    /// `--dsw-alias-border-l2`：搜索框/按钮描边。**带透明度，压在底色上**。
    static let borderL2 = dynamic(
        light: NSColor(red: 0, green: 0, blue: 0, alpha: 0.1),
        dark: NSColor(red: 1, green: 1, blue: 1, alpha: 0.12)
    )
    /// `--dsw-alias-interactive-bg-hover`：行 hover **与选中**共用的填充。
    ///
    /// 上游 `.sessionRow:hover` 与 `.sessionRow.selected` 是同一个变量 ——
    /// 抄的时候不许「顺手」把选中态改成强调色：那是另一套设计语言。
    static let interactiveHover = dynamic(
        light: NSColor(red: 38 / 255, green: 49 / 255, blue: 72 / 255, alpha: 0.06),
        dark: NSColor(red: 1, green: 1, blue: 1, alpha: 0.08)
    )
    /// `--dsw-alias-button-elevated-fill`：抬起按钮底色。
    static let buttonElevatedFill = dynamic(light: rgb(255, 255, 255), dark: rgb(67, 69, 74))
    /// `--dsw-alias-state-business-primary`：品牌色。**只出现在「模型正在动」上。**
    static let businessPrimary = dynamic(light: rgb(65, 118, 230), dark: rgb(103, 158, 254))
    /// `--dsw-alias-state-error-primary`：失败提示。
    static let errorPrimary = dynamic(light: rgb(236, 19, 19), dark: rgb(242, 90, 90))

    // MARK: 尺寸（三份 CSS module）

    /// `.root { padding: 6px 12px }` 的横向内边距，也是 `.regionArea` 的右侧让位量。
    static let sidebarInlinePadding: CGFloat = 12
    /// `.sectionHeader { height: 36px; margin-bottom: 4px; padding-left: 4px }`
    static let sectionHeaderHeight: CGFloat = 36
    static let sectionHeaderBottomMargin: CGFloat = 4
    static let sectionHeaderLeadingPadding: CGFloat = 4
    /// `.root:not(.rail) .sectionHeader { margin-top: 2px; margin-right: -4px }`
    ///
    /// 那个负右边距是刻意的：图标簇比行**更靠边** 4px（行右边界 = 区域右 −12，
    /// 图标簇 = −8）。抄漏它，展开态的搜索/加号会比官方整体左移 4px。
    static let sectionHeaderTopMargin: CGFloat = 2
    static let sectionHeaderTrailingOutset: CGFloat = -4
    /// `.projectRow { height: 34px }`
    static let projectRowHeight: CGFloat = 34
    /// `.sessionRow { height: 32px }`
    static let sessionRowHeight: CGFloat = 32
    /// `.projectRow, .sessionRow { border-radius: 8px; padding: 0 8px }`
    static let rowCornerRadius: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 8
    /// `.projectRow, .sessionRow { gap: 6px }`
    static let rowGap: CGFloat = 6
    /// `.slot { width: 16px }`：行首状态槽。
    static let statusSlotWidth: CGFloat = 16
    /// `.sessionRow .title { margin: 0 6px 0 4px }`
    static let sessionTitleLeadingGap: CGFloat = 4
    static let sessionTitleTrailingGap: CGFloat = 6
    /// `.flatList > * + * { margin-top: 2px }`
    static let rowSpacing: CGFloat = 2
    /// `.groupSection + .groupSection { margin-top: 4px }`
    static let groupSpacing: CGFloat = 4
    /// `.list { padding-bottom: 16px }`：给底部渐隐让路。
    static let listBottomPadding: CGFloat = 16
    /// `.iconButton { width: 28px; height: 28px; border-radius: 50% }`
    static let iconButtonSize: CGFloat = 28
    /// `.rail .iconButton { width: 36px; height: 36px }`
    static let railIconButtonSize: CGFloat = 36
    /// 图标字形边长。上游把它写在 JSX 的 `size` 上，不在 CSS 里：
    /// `IconSearchOutline16 size={searchExpanded ? 11 : 14}`、
    /// `IconProjectAddOutline16 size={wide ? 16 : 18}`、rail 的搜索 `size={18}`。
    static let searchGlyphSize: CGFloat = 14
    static let searchGlyphSizeExpanded: CGFloat = 11
    static let addGlyphSize: CGFloat = 16
    static let railGlyphSize: CGFloat = 18
    /// 行内字形：`IconFolderClose16` / `IconTriangleRightFill14` 都是 16 的盒。
    /// 第一版按 12 画，文件夹比官方小了整整一号。
    static let rowGlyphSize: CGFloat = 16
    /// `.rail .search { margin: 0 0 12px }` / `.collapsed` 的 12px 纵向节奏。
    static let railSpacing: CGFloat = 12
    /// `.searchExpanded { height: 30px; border-radius: 10px }`
    static let searchExpandedHeight: CGFloat = 30
    static let searchExpandedCornerRadius: CGFloat = 10
    /// `.fade { height: 24px }`：列表底部渐隐。
    static let listFadeHeight: CGFloat = 24

    // MARK: 字体（base.css 的 `-apple-system` 栈 = 系统字体）

    /// `.title { font-size: 14px; line-height: 20px }`
    static let title = Font.system(size: 14)
    /// `.newSession { font-weight: 500 }`
    static let titleMedium = Font.system(size: 14, weight: .medium)
    /// `.searchInput { font-size: 13px }`
    static let search = Font.system(size: 13)
    /// `.empty { font-size: 13px; padding: 16px 12px }`：一格都没有时的空态。
    static let empty = Font.system(size: 13)
    static let emptyVerticalPadding: CGFloat = 16
    static let emptyHorizontalPadding: CGFloat = 12
    /// `.searchStatus { font-size: 12px; padding: 10px 12px }`：搜索无结果。
    /// 与空态**不是**同一个样式（上游是两个类），抄的时候不许合并。
    static let searchStatusVerticalPadding: CGFloat = 10
    /// `.meta, .time { font-size: 12px }`
    static let meta = Font.system(size: 12)

    // MARK: 动效（`--ds-ease-in-out: cubic-bezier(0.4, 0, 0.2, 1)`）

    /// `base.css` 的 `--ds-ease-in-out`，用在搜索展开/收起上。
    static let easeInOut = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)

    // MARK: 实现细节

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    /// 一个跟随系统外观的颜色。
    ///
    /// 用 `NSColor` 的 dynamic provider 而不是 SwiftUI 的 `Color(light:dark:)`
    /// （不存在）或 asset catalog（这个 target 没有 bundle 资源）：外观切换时
    /// 由 AppKit 负责重解析，我们不需要自己观察 `colorScheme`。
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
