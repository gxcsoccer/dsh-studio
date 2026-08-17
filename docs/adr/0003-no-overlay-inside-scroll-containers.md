# ADR-0003 — 滚动容器内部不做 overlay

- 状态：**已采纳**
- 日期：2026-08-17
- 相关：[ARCHITECTURE.md §4](../../ARCHITECTURE.md)、[slot-map.md §7](../slot-map.md)

## 背景

原生视图和 Web 布局的关系只有两种：

- **evacuated（撤离）**：该区域整块离开 Web 布局，在原生 chrome 里占真实屏幕面积。Web 侧渲染零尺寸占位。
- **overlay（覆盖）**：原生视图按 Web 上报的 rect 悬浮在 WebView 之上，Web 侧渲染等尺寸透明占位撑住排版。

`conversation.chat.node` 是 `keyed` 插槽（key = `ChatNodeKind`），**技术上**允许「只把 `user` 类型的消息卡片换成原生」。这个粒度很诱人：一种卡片一种卡片地换，每次改动都极小。

要实现它只有 overlay 一条路 —— 消息卡片必须待在转录的排版流里。

## 问题

消息卡片位于**转录滚动容器内部**。在滚动容器里做 overlay，要求每一帧都满足：

1. Web 侧算出新的 rect；
2. 通过 `postMessage` 跨进程送到原生；
3. 原生更新视图 frame；
4. 与 WebView 自己的合成同一帧呈现。

第 4 条做不到。`WKWebView` 的滚动在自己的合成线程上跑（含惯性、rubber-band、`scroll-behavior: smooth`），而我们的 rect 要绕一圈 IPC。结果是**原生卡片相对网页内容漂移**，在快速滚动和惯性减速阶段尤其明显。这不是优化问题，是两套渲染管线不共享时钟的结构性问题。

叠加的麻烦还有：

- **裁剪**：卡片滚出容器时，overlay 视图要自己按容器边界裁剪，还得处理圆角与阴影。
- **层级**：Web 侧的浮层（tooltip、菜单、`shell.overlay`）会被原生 overlay 盖住，因为原生视图永远在 WebView 之上。
- **流式高度抖动**：`assistant-step` 在流式输出时高度持续变化，rect 每帧都在变 —— 上面那圈 IPC 每帧跑一次。
- **滚动锚定**：官方在追加内容时维持「贴底/锚定」行为，原生 overlay 不参与这套计算，会与之打架。

## 决定

**硬规则：滚动容器内部不允许 overlay。**

遇到这种插槽，**向上升级到最近的可撤离祖先**，把整块撤离并由原生自己渲染内部内容。

对 `conversation.chat.node` 而言，就是升级到 **`conversation.view` 整块撤离**：原生从 `session/event` 自己渲染整条转录（`LazyVStack` / `NSTableView` + 增量 diff + 自己的滚动锚定）。

`keyed` 的粒度收益不丢，只是**兑现的时机变了** —— 等我们已经在原生转录里之后（W6），再按 key 逐种补齐卡片渲染器，未覆盖的 key 走通用兜底卡片。

## 理由

- **滚动是原生的强项，不是要绕开的障碍。** 一旦整块撤离，惯性滚动、锚定、大列表复用、`ScrollView` 性能全部变成 SwiftUI/AppKit 的既有能力，而不是需要跨进程同步的难题。
- **overlay 的适用面本来就窄。** 它只在「尺寸小、位置稳定、不在滚动容器内」时成立 —— 例如 `conversation.input.model`、`conversation.input.plan` 这类嵌在 composer 工具行里的控件。而且它们是**过渡态**：等 `conversation.composer` 整块接管完成，这些 overlay 自动消失。
- **让约束显式，避免逐个插槽重新辩论。** 没有这条规则，每个滚动区内的插槽都会引发一次「这次要不要试试 overlay」的讨论，而每次的答案都一样。
- **失败模式不可接受。** overlay 漂移不是「有点卡」，是视觉撕裂 —— 用户会直接判定产品坏了，而这恰恰发生在最高频的交互（读消息）上。

## 后果

**接受：**

- W5 变成一个大工程：要自己实现流式转录渲染（增量、锚定、代码块、Markdown、长内容折叠）。这是本次迁移最贵的一步，且无法用小步子拆开。
  - 缓解：W5 之前先把 W1–W4 的流水线磨顺；W5 期间靠 `mirrored` 长期对照，不急着翻 `native`。
- 无法做到「只换一种消息卡片就上线」。第一次触碰转录就必须整块接管。

**换来：**

- 不会有任何滚动漂移问题。
- 原生转录一旦成立，W6 的按 key 补齐是纯增量工作，且每一步都在原生侧内部，不再涉及跨进程几何同步。

**规则的可执行形式：**
`NativeSlotProxy` 在上报 `slot/rect` 时携带 `scrollable` 标记（检测祖先是否为滚动容器）。宿主收到 `placement: overlay` 且 `scrollable: true` 的组合时**直接拒绝并报错**，而不是尽力渲染。让违规在开发期就崩，别留到用户那里才发现。
