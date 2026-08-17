# Slot Map — 迁移地图

这份文件是迁移的**账本底稿**：官方到底有哪些插槽、每个插槽的契约形状、我们打算怎么落位、排在哪一波。

**所有条目都来自官方源码实读**（`packages/client/**/contract/slots.ts` 的 `SlotMap` 声明合并 + `renderSlot()` 实际调用点），不是推测。上游是 developer preview，本表随 `tools/slot-snapshot` 的 CI 快照一起维护；对不上就大声失败。

术语见 [ARCHITECTURE.md §2](../ARCHITECTURE.md)：`kind` = 基数，`scope` = 数据上下文，`placement` = evacuated（撤离，默认）/ overlay（覆盖，受限）。

---

## 1. 插槽基数与我们的应对

先讲清四种 `kind` 对迁移意味着什么，这决定了「一个插槽能不能被部分替换」。

| kind | 语义 | 遮蔽方式 | 迁移含义 |
| --- | --- | --- | --- |
| `single` | 一格，一个占有者 | 同名 + 更低 priority | 整块换掉，全有或全无 |
| `list` | 多个贡献者按 `order` 排 | 一个 cell = 一个 `id`；按 id 分别遮蔽 | **可以只换其中一条**，其余官方条目继续渲染 |
| `keyed` | 按 `key` 分格派发 | 一个 cell = 一个 `key`；按 key 分别遮蔽 | **可以只换一种**（一种消息卡片 / 一种工具视图） |
| `chain` | 选择器路由的接管链，按 priority 升序试 | 加一个更低 priority 的链节，`select` 命中即接管 | **可以按条件接管**，不命中就落回官方 |

`keyed` 与 `chain` 是这套迁移能做得细的根本原因：粒度不是「一列」，而是「一种消息卡片」「一种条件下的输入框」。

---

## 2. 骨架层

| 插槽 | kind | scope | 声明处 | 官方占有者 | placement | 波次 |
| --- | --- | --- | --- | --- | --- | --- |
| `root` | single | root | `runtime/src/client/slots.ts` | `ui-layout` → `AppFrame` | evacuated | **W7** |
| `sidebar` | single | root | `ui-layout/src/client/index.ts` | `ui-sidebar` → `SidebarRoot` | evacuated | **W1** |
| `conversation` | single | session-maybe | `ui-layout` | `ui-conversation` → `ConversationRoot` | evacuated | W5 |
| `details` | single | session | `ui-layout` | `ui-conversation` → `DetailsPanel` | evacuated | **W2** |
| `shell.overlay` | list | root | `ui-layout` | 多插件贡献 | evacuated | W3 |

`root` 排最后不是保守，是必然：它是 `AppFrame`，声明了 `sidebar` / `conversation` / `details` / `shell.overlay` 四个子插槽。**声明即占有** —— 我们一旦遮蔽 `root`，就必须自己声明并托管全部子插槽。所以只有当四个孩子都已原生化，遮蔽 `root` 才是收尾动作而不是一次大爆炸。

`shell.overlay` 是 `list`：官方多个插件往里塞浮层。我们不整块接管，只按 id 逐条迁移，其余保留。

---

## 3. 侧栏（W1，首波）

| 插槽 | kind | scope | owner props | placement |
| --- | --- | --- | --- | --- |
| `sidebar` | single | root | `SidebarOwnerProps` | evacuated |
| `sidebar.workspaces` | single | root | `SidebarSectionOwnerProps` | **overlay** |
| `sidebar.settings` | single | root | `SidebarSettingsOwnerProps` | evacuated |
| `sidebar.footer.action` | list | root | `SidebarFooterActionOwnerProps` | evacuated |
| `sidebar.workspaces.directoryFlow` | single | root | `DirectoryFlowOwnerProps`（`ui-workspace` 声明） | evacuated |

`sidebar.workspaces` 的落位从 evacuated 改成 **overlay**，是 W1 实装后改的（[ARCHITECTURE.md §4.1](../ARCHITECTURE.md) 末尾的判据）：它是官方 `sidebar` 列**里**的一格，列宽与上下邻居都还归官方 shell，Web 侧必须继续留出这一格，原生视图才有位置可填。evacuated 只留给「整个容器都归我们」的那一天 —— 即 `sidebar` 这一行本身。`directoryFlow` 保持 evacuated：它是 `retired` 暗槽，原生侧用 `NSOpenPanel`，永不渲染，也就没有几何。

选它做首波的理由：

- **纯导航，零流式内容**，不涉及增量渲染与滚动锚定；
- 官方 `ui-sidebar` 的注入面只有两个动作（`startSession`、`toggleSidebar`），交棒面极窄；
- 原生收益立刻可见：列表密度、键盘导航、拖拽、右键菜单、`NSOutlineView` 级的大列表性能；
- 失败面小，而且有回落。

**注意 `sidebar` 的子插槽归属**：官方注释写明「shell 负责几何，`ui-workspace` 注册整个浏览区（header、搜索、会话列表、工作区弹窗），`ui-settings` 注册脚部触发器 + 设置面板」。所以遮蔽 `sidebar` 这一格时，我们必须**同时声明它的三个子插槽**（`sidebar.workspaces` / `sidebar.settings` / `sidebar.footer.action`），否则 `ui-workspace` 与 `ui-settings` 的注册会落到一个不存在的插槽上而抛错。

> 这是本设计里最容易踩的坑，写进 [migration-playbook.md](./migration-playbook.md) 的第 2 步检查项：**遮蔽一个 single 插槽 = 继承它的全部子插槽声明责任。**

两条路可选，W1 采用后者：

- (a) 一次性遮蔽 `sidebar` 并自己声明三个子槽 → 需同时原生化整条侧栏；
- (b) **先只遮蔽 `sidebar.workspaces`**（会话树/搜索/分组），把 `sidebar` 这一格留给官方 shell → 增量更小，第一刀更浅。

---

## 4. 设置与详情（W2）

| 插槽 | kind | scope | 声明处 | placement |
| --- | --- | --- | --- | --- |
| `details` | single | session | `ui-layout` | evacuated |
| `conversation.details.tool` | single | session | `ui-conversation` | evacuated |
| `settings.trigger` | single | root | `ui-settings` | evacuated |
| `settings.header` | single | root | `ui-settings` | evacuated |
| `settings.action` | list | root | `ui-settings` | evacuated |
| `settings.close` | single | root | `ui-settings` | evacuated |
| `settings.section` | list | root | `ui-settings` | evacuated |
| `settings.general.item` | list | root | `ui-settings` | evacuated |
| `settings.onboarding` | list | root | `ui-settings` | evacuated |
| `settings.plugins.tab` | list | root | `ui-settings` | evacuated |
| `settings.plugin.item` | list | root | `ui-settings-plugins` | evacuated |

设置面板是原生化性价比最高的一块：表单控件、偏好持久化、键盘与无障碍，SwiftUI 全是主场，而 Web 侧要手写一堆。而且 `settings.*` 大多是 `list`，**可以一项一项换**（`settings.section` / `settings.general.item` 按 id 逐条遮蔽），不需要一次性接管整个面板。

`settings.plugin.item` 直接服务 README 里的产品支柱 3「插件管理 UI」—— 让「一切皆插件」可见、可装、可关、可诊断。

---

## 5. 会话框架（W3）

| 插槽 | kind | scope | owner props | placement |
| --- | --- | --- | --- | --- |
| `conversation.session` | single | session | — | evacuated |
| `conversation.session.header` | single | session | — | evacuated |
| `conversation.session.header.actions` | list | session | `ConversationHeaderActionOwnerProps` | evacuated |
| `conversation.session.header.utilities` | list | session | `ConversationHeaderActionOwnerProps` | evacuated |
| `conversation.hero.workspace` | single | root | `EmptyWorkspaceOwnerProps` | evacuated |
| `conversation.hero.agentPreset` | single | root | `HeroAgentPresetOwnerProps` | evacuated |
| `conversation.hero.workspace.directoryFlow` | single | root | `DirectoryFlowOwnerProps` | evacuated |

会话标题栏原生化后可以直接并进 `NSToolbar`，这是「桌面是一等公民」最直观的体现。`hero.*` 是空态，正好对应产品支柱 4「第一次打开就能跑起来」，且完全静态、零风险。

---

## 6. 输入区（W4）— 官方留了 takeover 链

| 插槽 | kind | scope | owner props | placement |
| --- | --- | --- | --- | --- |
| **`conversation.composer`** | **chain** | session | `ComposerChainProps` | evacuated |
| `conversation.composer.bar` | single | session-maybe | `ComposerBarOwnerProps` | evacuated |
| `conversation.composer.dock` | list | session | `InputZone` | evacuated |
| `conversation.input.dock` | list | session | `InputZone` | evacuated |
| `conversation.input.left` | list | session | `InputZone` | overlay |
| `conversation.input.right` | list | session | `InputZone` | overlay |
| `conversation.input.model` | single | session | `InputControlOwnerProps` | overlay |
| `conversation.input.plan` | single | session | `InputControlOwnerProps` | overlay |
| `conversation.input.overlay` | list | session | —（`ui-input-trigger` 声明） | evacuated |

`conversation.composer` 的官方注释是决定性的：

> *"The composer takeover chain: entries are selector-routed replacements"*

**换输入框是官方设计里预留的动作。** chain 的语义是按 priority 升序逐个试 `select`，命中即接管、不命中继续往下 —— 天然的条件接管 + 自动回落。于是可以做到：普通文本输入走原生 composer，遇到某些特殊态（比如某个插件的自定义输入流程）自动落回官方实现。

输入区原生化的收益是本次迁移里最实在的一块：**输入法（中文候选窗）、快捷键、拖拽附件、粘贴图片、撤销栈** —— 这些在 WebView 里全是硬仗，在 AppKit/SwiftUI 里是既有能力。

`input.left` / `input.right` / `input.model` / `input.plan` 嵌在 composer 卡片内部的工具行里，是本设计中**少数允许 overlay 的插槽**：它们不在滚动容器内、尺寸小且稳定。但一旦 `conversation.composer` 整块接管完成，这四个就自动变成原生内部布局，overlay 随之消失 —— 所以它们的 overlay 只是过渡态，不是终态。

---

## 7. 转录与消息卡片（W5 / W6）— 本次迁移的硬核

### 7.1 硬规则先行

| 插槽 | kind | scope | placement |
| --- | --- | --- | --- |
| `conversation.view` | list | session | evacuated（**整块**） |
| `conversation.chat.node` | keyed | session | 随 `conversation.view` 一起原生 |
| `conversation.chat.commandview` | keyed | session | 同上 |
| `conversation.chat.turnTail` | chain | session | 同上 |
| `conversation.chat.assistant-actions` | list | session | 同上 |
| `tool.call.toolview` | keyed | session | 同上 |

`conversation.chat.node` 是 `keyed`，**技术上**允许只换一种消息卡片。但它位于转录滚动容器内部，逐节点 overlay 会掉帧、错位、与惯性滚动撕裂 —— 见 [ADR-0003](./adr/0003-no-overlay-inside-scroll-containers.md)。

因此 W5 的做法是：**向上升级到 `conversation.view` 整块撤离**，由原生从 `session/event` 自己渲染转录（`LazyVStack` / `NSTableView` + 增量 diff）。`keyed` 的粒度收益在 W6 兑现 —— 那时候我们已经在原生转录里，按 `key` 逐种补齐卡片渲染器，没换到的种类先走一个通用回落卡片。

### 7.2 已知的 `conversation.chat.node` key（= 迁移清单）

来自 `ui-conversation/src/client/chat/register-node-renderers.ts` 等注册点：

| key | 内容 | W6 顺序建议 |
| --- | --- | --- |
| `user` | 用户消息 | 1（最简单、最高频） |
| `assistant-step` | 助手回复（流式，`status: running/settled/interrupted`，含 `blocks`） | 2（最难也最核心） |
| `tool-call` | 工具调用（`ui-tool`，含 root/children/parents 树） | 3 |
| `command` | 斜杠命令 | 4 |
| `steering` | 中途干预消息 | 5 |
| `context` | 上下文注入消息 | 6 |
| `compaction` / `manual-compaction` | 上下文压缩摘要 | 7 |
| `model-retry` | 模型重试（含 `attempts`） | 8 |
| `turn-error` / `turn-max-tokens` | 轮次错误 / 触顶 | 9 |
| `workflow-run` | 工作流运行（`ui-workflow-run`） | 10 |
| `unknown` | **官方自带的未知节点回落** | 保留官方 |

最后一行值得注意：官方自己就有 `unknown` 兜底渲染器（`conversation-nodes/fallback.ts`）。**这说明上游预期节点种类会增长**，也印证我们必须给原生转录准备同款兜底 —— 新增的 key 没有原生渲染器时不能白屏。

`ChatNodeKind` 本身是从 `ChatNodeDataMap` 声明合并出来的，任何插件都能加新种类。所以原生侧的卡片派发表必须是**开放的**（未知 key → 通用卡片 + 上报），不能是穷举 switch。

---

## 8. 波次汇总

| 波 | 插槽数 | 主要插槽 | 主要风险 | 完成信号 |
| --- | --- | --- | --- | --- |
| W1 | 1→5 | `sidebar.workspaces`（再扩到整条 `sidebar`） | 子插槽声明责任 | 会话树全原生，官方侧栏零渲染 |
| W2 | 11 | `settings.*`、`details` | 表单状态一致性 | 设置面板与详情面板全原生 |
| W3 | 7 | `conversation.session.header`、`hero.*`、`shell.overlay` | 与 `NSToolbar` 融合 | 标题栏进原生工具栏 |
| W4 | 9 | **`conversation.composer`（chain takeover）** | 输入法、提交语义 | 原生输入框成为默认，overlay 归零 |
| W5 | 1 | `conversation.view`（整块 + 转录渲染） | 流式增量、滚动锚定 | 转录由原生从 `session/event` 渲染 |
| W6 | ~12 keys | `chat.node` / `tool.call.toolview` 按 key | 卡片种类长尾 | 高频 key 全原生，长尾走兜底 |
| W7 | 1 | `root` | 继承四个子插槽声明 | WebView 不再渲染任何 UI |
| W8 | 0 | 拆除 client 半与 WebView | — | 领域数据路径零改动（[ADR-0002](./adr/0002-domain-data-bypasses-the-webview.md)） |

---

## 9. 不迁移的插槽

明确留给官方，不进任何波次：

- `conversation.chat.node` 的 `unknown` key —— 官方兜底，我们只在原生侧做同款，不遮蔽它；
- `settings.plugins.tab` 里第三方插件贡献的条目 —— 那是别人的 UI，遮蔽等于劫持；
- 任何**只有第三方插件注册**的 `list` 条目 —— 生态贡献必须保持能显示，否则 Studio 就成了生态的黑洞。

这条边界不是客气，是产品判断：Studio 的价值是把桌面做成一等公民，不是把别人的插件挤出去。
