import SwiftUI
import DSHKit
import DSHClient
import DSHSurface

/// **W1 的原生侧栏** —— 替换官方 `sidebar.workspaces`。
///
/// 这个视图是整套架构的分界线（reference/native-slot-proxy.md §4 末尾）：
///
/// - 领域数据（工作区、会话、running 状态、标题投影）从 `DSHClient` 拿 ——
///   loopback 数据通道，**不经 WebView**（ADR-0002）。
/// - 编排状态（wide / selected）从 `instance.props` 拿 —— 控制通道。
/// - 领域动作（新建会话、归档、重命名）→ `client.rpc(...)`。
/// - 必须由 Web 侧 `ctx` 完成的回调（官方注入面）→ `instance.invoke(...)`。
///
/// 键盘可达 + VoiceOver 标签完整是本视图的验收门（migration-playbook.md §③）：
/// 原生化的意义就在这里，做丢了就白换。
///
/// ## 视觉：不是「原生风」，是官方设计语言的原生复刻
///
/// 第一版这里用的是 SwiftUI 默认值 —— `.headline` 标题、`.roundedBorder` 搜索框、
/// `List(.sidebar)` 列表。它们各自都「像 macOS」，拼进官方侧栏就是两种设计语言
/// 中间划了一道缝。所以现在每一处尺寸和颜色都对着上游 CSS 抄（`SidebarTokens`），
/// 结构也对着 `WorkspaceBrowser.tsx` 抄：
///
/// ```
/// .sectionHeader (36)   工作区                       🔍  ＋
/// .list (flex 1)        📁 dsh-studio                      ← .projectRow (34)
///                        ● 修 W1 几何            3分钟      ← .sessionRow (32)
///                          会话标题              2小时
/// ```
///
/// 结构里**没有** `List`：`List(.sidebar)` 自带 macOS 的选中高亮（强调色圆角条）、
/// 自己的行高与内缩，全都和官方的 `radius 8 / 32px / interactive-bg-hover` 冲突，
/// 而这些恰好都不可关。用 `ScrollView` + 自绘行是为了拿回**逐像素的控制权**。
struct WorkspacesRailView: View {
    /// 编排：wide（折叠态）/ selected / disabled。
    private let instance: SlotInstance
    /// 相对时间的「现在」。可注入 —— 离屏渲染要钉死它才能得到确定性的 PNG。
    private let now: Date

    @Environment(DSHClient.self) private var client
    @State private var localSelection: String?
    @State private var searchText = ""
    @State private var searchExpanded = false
    @State private var actionFailure: String?
    @FocusState private var searchFocused: Bool

    init(instance: SlotInstance, now: Date = Date()) {
        self.instance = instance
        self.now = now
    }

    var body: some View {
        Group {
            if instance.props.collapsed {
                collapsedRail
            } else {
                expandedRegion
            }
        }
        // 这一格的背景。
        //
        // 画它而不是留透明：透明能自动跟上官方那条侧栏的底色（我们就盖在它上面），
        // 但一旦用户在官方设置里把主题**手动**掰到与系统相反的一侧，透明会得到
        // 「深色底 + 浅色文字色」这种读不了的组合。画自己的底色至少保证这一块
        // 内部自洽。（跟随 Web 主题仍是未解决问题，见交付报告 / known-gaps G-8。）
        .background(SidebarTokens.sidebarFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作区与会话")
        .onChange(of: instance.props.selected) { _, _ in
            // Web 侧确认了选中态 → 放弃本地乐观值。
            localSelection = nil
        }
    }

    // MARK: 展开态

    /// `.root { flex: 1; min-height: 0; padding-right: 12px }`
    private var expandedRegion: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
                .padding(.top, SidebarTokens.sectionHeaderTopMargin)
                .padding(.trailing, SidebarTokens.sectionHeaderTrailingOutset)
                .padding(.bottom, SidebarTokens.sectionHeaderBottomMargin)
            // 横幅与列表里的失败态说的是**同一件事**，所以只说一次。
            //
            // 列表自己已经画了失败态（`.unavailable`：零行 + 原因 + 重试）时，
            // 横幅就是同一句话的第二遍 —— 244px 宽的一列里重复两遍红字，读者
            // 反而更难判断发生了什么。只有**还有行**的时候横幅才不可替代：那时
            // 列表画的是仍然有效的旧事实，横幅说的是链路怎么了、列表末尾那句
            // `staleNotice` 说的是这些行还能不能信（见 `.stale`）。
            if let banner = client.link.bannerText, !client.dataAvailability.isUnavailable {
                disconnectionBanner(banner)
            }
            sessionList
            if let actionFailure {
                Text(actionFailure)
                    .font(SidebarTokens.meta)
                    .foregroundStyle(SidebarTokens.errorPrimary)
                    .padding(.horizontal, SidebarTokens.rowHorizontalPadding)
                    .padding(.vertical, 6)
                    .accessibilityLabel("上一次操作失败：\(actionFailure)")
            }
        }
        .padding(.trailing, SidebarTokens.sidebarInlinePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `.sectionHeader`：标题 + 内联搜索 + 尾部动作。
    ///
    /// 搜索展开时标题让位（上游 `.sectionLabelHidden` 把 `max-width` 收到 0），
    /// 这里用同一条 `--ds-ease-in-out` 曲线做同样的事。
    private var sectionHeader: some View {
        HStack(spacing: 4) {
            if !searchExpanded {
                Text(instance.props.label ?? "工作区")
                    .font(SidebarTokens.title)
                    .foregroundStyle(SidebarTokens.labelTertiary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            searchControl
            if !searchExpanded {
                iconButton(
                    // `IconProjectAddOutline16`：带 + 的文件夹，不是圆圈里的加号。
                    // 上游这颗按钮点开工作区选择器，最终调的正是我们注入面上的
                    // `startSession(workspaceId)` —— 图形与语义在这里是一致的。
                    "folder.badge.plus",
                    label: "新建会话",
                    hint: newSessionHint,
                    glyph: SidebarTokens.addGlyphSize
                ) { newSession() }
                    .disabled(instance.props.disabled)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .padding(.leading, SidebarTokens.sectionHeaderLeadingPadding)
        .frame(height: SidebarTokens.sectionHeaderHeight)
        .animation(SidebarTokens.easeInOut, value: searchExpanded)
    }

    /// `.search` / `.searchExpanded`：收起时是 28×28 圆形图标钮，展开时是一条
    /// 30px 高、`border-l2` 描边、radius 10 的胶囊。
    @ViewBuilder
    private var searchControl: some View {
        if searchExpanded {
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: SidebarTokens.searchGlyphSizeExpanded))
                    .frame(width: SidebarTokens.iconButtonSize, height: SidebarTokens.searchExpandedHeight)
                    .foregroundStyle(SidebarTokens.labelSecondary)
                TextField("搜索会话…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(SidebarTokens.search)
                    .foregroundStyle(SidebarTokens.labelPrimary)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索会话")
                iconButton("xmark.circle.fill", label: "清除搜索", size: 24) {
                    searchText = ""
                    searchExpanded = false
                }
            }
            .frame(height: SidebarTokens.searchExpandedHeight)
            .overlay(
                RoundedRectangle(cornerRadius: SidebarTokens.searchExpandedCornerRadius, style: .continuous)
                    .strokeBorder(SidebarTokens.borderL2, lineWidth: 1)
            )
            .onAppear { searchFocused = true }
        } else {
            iconButton("magnifyingglass", label: "搜索会话", hint: "展开搜索框") {
                searchExpanded = true
            }
        }
    }

    private var newSessionHint: String {
        instance.can("startSession")
            ? "调用官方侧栏的新建会话动作"
            : "通过数据通道创建一个新会话"
    }

    /// `.list`：唯一的滚动区。行间 2px，分组间 4px，底部留 16px。
    ///
    /// 里面是 `VStack` 而**不是** `LazyVStack`：上游 `.list` 也没有虚拟化
    /// （它靠每组的 `.sessionOverflowButton` 折叠溢出行来限量，而不是按可视区
    /// 懒挂载），所以懒加载在这里换不来行为上的对等。而它有两个实打实的代价：
    /// 懒容器按「可视矩形」决定挂载，离屏渲染（`ImageRenderer`）没有可视矩形，
    /// 于是一整列行在快照里**全部为空** —— 那是我们唯一的视觉证据通道；
    /// 另外行的 hover/选中态在懒挂载时会丢 `@State`。
    private var sessionList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SidebarTokens.groupSpacing) {
                ForEach(client.workspaces) { workspace in
                    section(
                        title: workspace.title,
                        path: workspace.path,
                        sessions: filtered(client.visibleSessions(in: workspace))
                    )
                }
                let loose = filtered(client.looseSessions())
                if !loose.isEmpty {
                    // 上游同样把「没有工作区的会话」显示成一个 project row，
                    // 标签取字典文案（`group.ungrouped` = 未分组），而不是
                    // 某个工作区名（`Rows.tsx`：the ungrouped bucket has no
                    // workspace title）。
                    section(title: "未分组", path: nil, sessions: loose)
                }
                listStatus
            }
            .padding(.bottom, SidebarTokens.listBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
        // `.fade`：贴在列表可视底边的 24px 渐隐（transparent → sidebar-fill）。
        // 它跟着主题走，所以用同一个 `sidebarFill` token 而不是写死白色。
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [SidebarTokens.sidebarFill.opacity(0), SidebarTokens.sidebarFill],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: SidebarTokens.listFadeHeight)
            .allowsHitTesting(false)
        }
        .accessibilityLabel("会话树")
        .accessibilityHint("使用 Tab 与方向键在会话间移动，回车打开")
    }

    /// 列表末尾那一行状态 —— **三态分开画**。
    ///
    /// 本轮修的 bug 就在这里：这块地方原来只区分「没会话」与「搜索无匹配」，
    /// 于是数据通道断了（进程死了 / token 过期 / 协议漂移）时，用户看到的是
    /// 一句语气笃定的「暂无会话」。控制通道那边我们花了心跳 + 崩溃退位去避免
    /// 「显示得好好的但其实是死的」，数据通道上却留了同一个坑，而且更阴险：
    /// 控制通道死了会整块退回官方 Web UI，这个只会安静地告诉用户「你没有会话」。
    ///
    /// 判据不在视图里，在 `DSHClient.dataAvailability`（纯函数、可单测）：视图
    /// 只把四个分支映射到四种画法。下一个列表插槽（W2）照抄这个 `switch` 即可。
    @ViewBuilder
    private var listStatus: some View {
        switch client.dataAvailability {
        case .unavailable(let reason, let retryable):
            failureState(reason: reason, retryable: retryable)
        case .pending:
            connectingState
        case .empty:
            emptyState
        case .stale(let reason, _):
            // 行还在上面画着，但它们是**上一次成功读到**的样子。这里补一句
            // 「可能已过期」：不写这句，一份冻住的列表和正常运行长得一模一样
            // （G-13）。搜索过滤空了也照样要说，过期和过滤是两件独立的事。
            VStack(alignment: .leading, spacing: 0) {
                if !searchText.isEmpty, isFilteredToNothing { searchStatus }
                staleNotice(reason: reason)
            }
        case .populated:
            // 有行但被搜索过滤空了 → 上游的 `.searchStatus`。
            if !searchText.isEmpty, isFilteredToNothing { searchStatus }
        }
    }

    /// 「你看到的可能不是现在」—— 过期提示。
    ///
    /// 排版沿用 `.searchStatus`（12px / 10-12），墨色用 `errorPrimary`：它是
    /// 一句关于**可信度**的警告，不是终态结论，所以不占 `.empty` 那个盒子。
    ///
    /// 文案里**不重复**失败原因：那句已经在顶部横幅里了（横幅在有行时一定会
    /// 显示）。两处各说一件事 —— 横幅说链路怎么了，这里说屏幕上这些行还能不能
    /// 当现状；原因说两遍只会让 244px 宽的一列更难读。
    private func staleNotice(reason: DisconnectReason?) -> some View {
        Text("以上是最后一次同步的结果，可能已过期")
            .font(SidebarTokens.meta)
            .foregroundStyle(SidebarTokens.errorPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SidebarTokens.emptyHorizontalPadding)
            .padding(.vertical, SidebarTokens.searchStatusVerticalPadding)
            .accessibilityLabel("列表可能已过期：\(reason?.headline ?? "正在重连")")
    }

    /// 空态与「搜索无结果」是上游的**两个**类：`.empty`（13px / padding 16-12）
    /// 与 `.searchStatus`（12px / padding 10-12）。合成一个会让搜索态的空行
    /// 忽然长高 6px。
    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            Text("暂无会话")
                .font(SidebarTokens.empty)
                .foregroundStyle(SidebarTokens.labelTertiary)
                .padding(.horizontal, SidebarTokens.emptyHorizontalPadding)
                .padding(.vertical, SidebarTokens.emptyVerticalPadding)
                .accessibilityLabel("暂无会话")
        } else {
            searchStatus
        }
    }

    /// `.searchStatus`：12px / padding 10-12。**不许**与 `.empty` 合并。
    private var searchStatus: some View {
        Text("无匹配结果")
            .font(SidebarTokens.meta)
            .foregroundStyle(SidebarTokens.labelTertiary)
            .padding(.horizontal, SidebarTokens.emptyHorizontalPadding)
            .padding(.vertical, SidebarTokens.searchStatusVerticalPadding)
    }

    /// 「还在连」—— 既不是空也不是失败，所以它自己是一态。
    ///
    /// 沿用 `.searchStatus` 的排版（12px / 10-12）而不是 `.empty`：它是一句
    /// 过程性的状态说明，和「搜索无结果」同一类，不是终态结论。
    private var connectingState: some View {
        Text("正在连接 dsh runtime…")
            .font(SidebarTokens.meta)
            .foregroundStyle(SidebarTokens.labelTertiary)
            .padding(.horizontal, SidebarTokens.emptyHorizontalPadding)
            .padding(.vertical, SidebarTokens.searchStatusVerticalPadding)
            .accessibilityLabel("正在连接 dsh runtime")
    }

    /// **失败态**：说清是「连接问题」，不是「你没有会话」，并给一颗能点的重试。
    ///
    /// 视觉沿用上游 `.empty` 的排版盒（padding 16-12、13px 标题），颜色用既有
    /// 的 `errorPrimary` / `labelTertiary` / `businessPrimary` 三个 token
    /// （与断连横幅同源），不引入新的字号或颜色。
    private func failureState(reason: DisconnectReason, retryable: Bool) -> some View {
        VStack(alignment: .leading, spacing: SidebarTokens.groupSpacing) {
            HStack(spacing: SidebarTokens.rowGap) {
                // 与断连横幅同一个字形：两处说的是同一件事。
                Image(systemName: "bolt.horizontal.circle")
                    .font(SidebarTokens.meta)
                Text(reason.headline ?? "连不上 dsh runtime")
                    .font(SidebarTokens.empty)
                    .lineLimit(2)
            }
            .foregroundStyle(SidebarTokens.errorPrimary)
            if let remedy = reason.remedy {
                Text(remedy)
                    .font(SidebarTokens.meta)
                    .foregroundStyle(SidebarTokens.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 这一句是空态与失败态的分界线，用**正面陈述**而不是自我辩解：
            // 说清「零行的成因是连接，不是你的数据」，而不是引用另一处 UI 文案。
            Text("列表为空是连不上导致的，不是你没有会话。")
                .font(SidebarTokens.meta)
                .foregroundStyle(SidebarTokens.labelTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button(retryable ? "重试连接" : "修好后重试") { client.retryNow() }
                .buttonStyle(.plain)
                .font(SidebarTokens.meta)
                .foregroundStyle(SidebarTokens.businessPrimary)
                .accessibilityLabel("重新连接 dsh runtime")
                .accessibilityHint(reason.remedy ?? "重新读取 bridge.json 并重连数据通道")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SidebarTokens.emptyHorizontalPadding)
        .padding(.vertical, SidebarTokens.emptyVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("数据通道不可用")
        .accessibilityValue(reason.headline ?? reason.code)
    }

    /// 搜索把所有行都过滤掉了吗（只在**确实有数据**时才有意义）。
    private var isFilteredToNothing: Bool {
        client.workspaces.allSatisfy { filtered(client.visibleSessions(in: $0)).isEmpty }
            && filtered(client.looseSessions()).isEmpty
    }

    @ViewBuilder
    private func section(title: String, path: String?, sessions: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: SidebarTokens.rowSpacing) {
            projectRow(title: title, path: path)
            ForEach(sessions) { session in
                sessionRow(session)
            }
        }
    }

    /// `.projectRow`：34px，行首 16px 文件夹槽。
    private func projectRow(title: String, path: String?) -> some View {
        SidebarRow(height: SidebarTokens.projectRowHeight, selected: false) {
            HStack(spacing: SidebarTokens.rowGap) {
                // `IconFolderClose16`：闭合文件夹，16 的字形盒、tertiary 墨色。
                Image(systemName: "folder")
                    .font(.system(size: SidebarTokens.rowGlyphSize))
                    .frame(width: SidebarTokens.statusSlotWidth)
                    .foregroundStyle(SidebarTokens.labelTertiary)
                Text(title)
                    .font(SidebarTokens.title)
                    .foregroundStyle(SidebarTokens.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("工作区 \(title)")
        .accessibilityValue(path ?? "")
    }

    /// `.sessionRow`：32px，状态槽 16px，标题左 4 右 6，右侧 12px 灰色相对时间。
    private func sessionRow(_ session: SessionSummary) -> some View {
        Button {
            select(session.sessionId.rawValue)
        } label: {
            SidebarRow(height: SidebarTokens.sessionRowHeight, selected: isSelected(session)) {
                HStack(spacing: 0) {
                    statusSlot(session)
                    Text(session.displayTitle)
                        .font(SidebarTokens.title)
                        .foregroundStyle(SidebarTokens.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, SidebarTokens.sessionTitleLeadingGap)
                        .padding(.trailing, SidebarTokens.sessionTitleTrailingGap)
                    Spacer(minLength: 0)
                    Text(session.relativeUpdatedLabel(now: now))
                        .font(SidebarTokens.meta)
                        .foregroundStyle(SidebarTokens.labelTertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("归档会话") { archive(session.sessionId) }
            Button("重命名会话") { rename(session.sessionId) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("会话 \(session.displayTitle)")
        .accessibilityValue(session.running ? "进行中" : "空闲")
        .accessibilityHint("回车打开该会话，右键可归档")
        .accessibilityAddTraits(isSelected(session) ? [.isButton, .isSelected] : .isButton)
    }

    /// `.slot`：16px 宽的状态槽。running 用上游那颗像素追逐点（`SidebarStateDot`），
    /// 其余状态留空 —— 与上游 `showStatus` 一致。
    private func statusSlot(_ session: SessionSummary) -> some View {
        ZStack {
            if session.running {
                SidebarStateDot()
            }
        }
        .frame(width: SidebarTokens.statusSlotWidth, height: 20)
        .accessibilityHidden(true)
    }

    private func disconnectionBanner(_ text: String) -> some View {
        // 断连横幅：设计里点名要原生化的第一个东西（bridge-contract.md §2.3）。
        HStack(spacing: SidebarTokens.rowGap) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 12))
            Text(text)
                .font(SidebarTokens.meta)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(SidebarTokens.errorPrimary)
        .padding(.horizontal, SidebarTokens.rowHorizontalPadding)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SidebarTokens.rowCornerRadius, style: .continuous)
                .fill(SidebarTokens.errorPrimary.opacity(0.12))
        )
        .padding(.bottom, SidebarTokens.groupSpacing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("运行时连接状态")
        .accessibilityValue(text)
    }

    // MARK: 折叠态（`.rail`）

    /// 折叠导轨：上游只留两个 36×36 的圆形图标钮，**不显示工作区首字母**。
    ///
    /// 顺序是「＋ 在上、🔍 在下」—— 那是上游的 DOM 顺序：`.sectionHeader` 里放
    /// 的是 headerActions（加号），搜索是紧跟在 header **之后**的
    /// `{!wide && <div className={css.search}>}`。把它们反过来（第一版就是反的）
    /// 是一眼能看出的接缝，因为官方展开态里搜索在加号左边，很容易想成上下也一样。
    ///
    /// 点任意一个先请求官方把侧栏展开（`expandSidebar` 是官方给这一格的注入面
    /// 动作），再做本来的事 —— 折叠态下没有地方显示结果。
    private var collapsedRail: some View {
        VStack(spacing: SidebarTokens.railSpacing) {
            iconButton(
                "folder.badge.plus",
                label: "新建会话",
                size: SidebarTokens.railIconButtonSize,
                glyph: SidebarTokens.railGlyphSize
            ) {
                newSession()
            }
            .disabled(instance.props.disabled)
            iconButton(
                "magnifyingglass",
                label: "搜索会话",
                size: SidebarTokens.railIconButtonSize,
                glyph: SidebarTokens.railGlyphSize
            ) {
                expandSidebar()
                searchExpanded = true
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("折叠的工作区导轨")
    }

    /// `.iconButton`：圆形，hover 时填 `interactive-bg-hover`。
    ///
    /// 字形边长与按钮边长分开传：上游的 `size` 写在 JSX 上，和 CSS 里的按钮盒
    /// 尺寸不是一回事（28 的盒里可能是 14 的搜索、也可能是 16 的加号）。第一版
    /// 用「按钮大就用大字形」猜，结果展开态的加号比官方小了 2px。
    private func iconButton(
        _ symbol: String,
        label: String,
        hint: String? = nil,
        size: CGFloat = SidebarTokens.iconButtonSize,
        glyph: CGFloat = SidebarTokens.searchGlyphSize,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HoverCircle(size: size) {
                Image(systemName: symbol)
                    .font(.system(size: glyph))
                    .foregroundStyle(
                        // `.rail .iconButton { color: label-primary }`，
                        // 展开态是 `.iconButton { color: label-secondary }`。
                        size >= SidebarTokens.railIconButtonSize
                            ? SidebarTokens.labelPrimary
                            : SidebarTokens.labelSecondary
                    )
            }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }

    // MARK: 选中态

    private func isSelected(_ session: SessionSummary) -> Bool {
        (localSelection ?? instance.props.selected) == session.sessionId.rawValue
    }

    private func filtered(_ sessions: [SessionSummary]) -> [SessionSummary] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: 动作

    /// 选中一个会话。
    ///
    /// ⚠️ 与文档不符之处：reference/native-slot-proxy.md §4 写的是
    /// `client.rpc(.sessionOpen(id))`，但上游 `RpcMethodMap` 里**没有**
    /// `session.open` —— 「当前打开哪个会话」是壳的导航状态，不是 runtime
    /// 的领域事实。所以这里走注入面（`selectSession`），没有该动作时退化为
    /// 纯本地选中态。详见交付报告。
    private func select(_ sessionID: String) {
        localSelection = sessionID
        guard instance.can("selectSession") else { return }
        instance.invokeDetached("selectSession", [.string(sessionID)])
    }

    /// 请求官方把折叠的侧栏展开（官方注入面 `expandSidebar`）。
    private func expandSidebar() {
        guard instance.can("expandSidebar") else { return }
        instance.invokeDetached("expandSidebar")
    }

    /// 新建会话。
    ///
    /// 优先走 Web 注入面（官方 `startSession` 会顺带处理导航与目录流程）；
    /// 没有该动作时用数据通道的 `session.create` 兜底。
    private func newSession() {
        if instance.can("startSession") {
            instance.invokeDetached("startSession")
            return
        }
        Task { @MainActor in
            do {
                _ = try await client.createSession(in: client.workspaces.first?.workspaceId)
                actionFailure = nil
            } catch {
                actionFailure = "新建会话失败：\(error)"
            }
        }
    }

    private func archive(_ sessionID: SessionID) {
        Task { @MainActor in
            do {
                try await client.archiveSession(sessionID)
                actionFailure = nil
            } catch {
                actionFailure = "归档失败：\(error)"
            }
        }
    }

    private func rename(_ sessionID: SessionID) {
        Task { @MainActor in
            do {
                // W1 先用一个确定性的默认名；输入框留给 W2 的表单原生化。
                try await client.renameSession(sessionID, title: "未命名会话")
                actionFailure = nil
            } catch {
                actionFailure = "重命名失败：\(error)"
            }
        }
    }
}

/// 一行的外壳：固定高度 + radius 8 + hover/选中同色填充。
///
/// hover 与 selected 用**同一个** token 是上游的结论（`Rows.module.css` 里
/// `.sessionRow:hover` 与 `.sessionRow.selected` 都是 `interactive-bg-hover`），
/// 不是这里图省事。
private struct SidebarRow<Content: View>: View {
    let height: CGFloat
    let selected: Bool
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, SidebarTokens.rowHorizontalPadding)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SidebarTokens.rowCornerRadius, style: .continuous)
                    .fill(selected || hovering ? SidebarTokens.interactiveHover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: SidebarTokens.rowCornerRadius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// `.iconButton`：圆形 hover 底。
private struct HoverCircle<Content: View>: View {
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        content()
            .frame(width: size, height: size)
            .background(Circle().fill(hovering ? SidebarTokens.interactiveHover : Color.clear))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}
