# Known Gaps — 实现暴露的设计缺口

W1 实现（`packages/studio-client`、`packages/studio-surface`、`apps/macos`）完成后，有三个缺口是**设计阶段没看出来、写代码才暴露**的。记在这里而不是埋在 commit message 里，因为它们会影响后续波次的取舍。

每一条都注明：现状怎么绕过的、什么时候必须真正解决、以及是否需要上游配合。

---

## G-1 `slot/rect` 只给几何，不给 z-order 与裁剪祖先

**问题**
overlay 落位的原生视图永远在 WKWebView 之上。但 Web 侧上报的 `rect` 只有位置和尺寸，没有：

- z-order —— 该插槽是否被 Web 侧的浮层（tooltip、菜单、`shell.overlay`）遮挡；
- 裁剪祖先链 —— 该插槽是否被祖先 `overflow: hidden` 部分裁掉。

于是原生视图**无法自证「我现在该不该显示、该被裁到多大」**。

**现状绕过**
用 `scrollable` 一刀切：只要检测到滚动祖先就**直接拒绝** overlay（[ADR-0003](./adr/0003-no-overlay-inside-scroll-containers.md)，`NativeSlotHost.swift` 强制执行）。这挡住了最严重的漂移，但**没有解决遮挡问题** —— 一个不在滚动容器里、却被 Web 浮层盖住的 overlay 插槽，原生视图仍会浮在浮层之上。

**何时必须解决**
W4。`conversation.input.left/right/model/plan` 是设计里唯一允许 overlay 的四个插槽，而它们**恰好**会被模型选择器、计划面板这类 Web 浮层覆盖。

**倾向的解法**
不扩 `slot/rect`，而是**取消这四个插槽的 overlay 过渡态**：W4 一次性把 `conversation.composer` 整块撤离，让这四个控件直接变成原生 composer 的内部布局。设计文档已经把它们标为「过渡态，随 composer 接管消失」—— 这个缺口说明**过渡态不该存在，应该直接跳到终态**。

如果确实需要保留 overlay，则需给 `slot/rect` 增加 `clipRect`（祖先裁剪后的可见矩形）与 `occluded: boolean`，由 Web 侧用 `elementFromPoint` 采样判定。成本不低，且每帧都要算 —— 这也是倾向前一种解法的原因。

---

## G-2 manifest 未定义「父插槽被接管时，子插槽的语义」

**问题**
官方 `ui-slots` 的规则是**声明即占有**：注册时用 `children` 声明的子插槽，注册者成为唯一所有者。于是遮蔽一个声明了子槽的插槽时，我们必须原样声明其全部子槽 —— 这一条设计文档写到了（[migration-playbook §②](./migration-playbook.md)）。

但**没写清**的是：父槽被我们接管后，子槽的 `mode` 该怎么解释？

- 父槽 `native`、子槽未列出（默认 `web`）→ 谁来渲染这个子槽？官方组件注册在我们声明的子槽上，可我们的原生父视图里并没有给它留位置。
- 父槽 `native`、子槽 `native` → 两个原生视图的嵌套关系由谁决定？
- 父槽 `mirrored`、子槽 `native` → 语义完全未定义。

**现状绕过**
W1 保守处理：**只接管 `sidebar.workspaces` 子槽，不接管父槽 `sidebar`**，把几何与子槽归属继续留给官方 shell。Swift 侧测试里把这条钉住了（*"W1 只接管 `sidebar.workspaces`、不接管父 `sidebar`"*）。

**何时必须解决**
W7 —— 遮蔽 `root` 时无法回避，因为 `root` 声明了 `sidebar` / `conversation` / `details` / `shell.overlay` 四个子槽。届时必须定义清楚：**我们的原生父视图如何为「仍是 web 的子槽」保留一块可嵌入区域。**

**这暴露了一个更深的问题**
「父原生 + 子 Web」意味着要在原生视图内部反向嵌入一块 WebView 区域 —— 也就是从 evacuated 退回 overlay，而且是最坏的一种（原生在下、Web 在上）。

因此更可能的结论是：**父槽的接管必须是自下而上的**，即父槽只有在其全部子槽都已 `native` 之后才允许接管。这条应该写成 manifest 的第 7 条解析规则并在代码里强制。设计文档目前只在波次排序上隐含了这个顺序（`root` 排 W7），但没有把它变成机制。

---

## G-3 控制通道没有心跳，Web 侧静默死亡发现不了

**问题**
控制通道只有握手（`surface/ready`）和按需的 req/res。如果 WebView 里的 client 插件**静默死掉**（JS 异常导致事件循环卡死、页面被系统回收但 WebView 实例仍在），宿主不会立刻知道 —— 只能等下一次 `slot/invoke` 或 `surface/reconfigure` 超时（5s）才发现。

在此期间，原生插槽视图仍然显示，但它的 `slot/invoke` 全部无效：**用户点得到、点了没反应**。这比白屏更糟。

**现状绕过**
`SurfaceCoordinator` 有 15s 握手 watchdog（未收到 `surface/ready` → 降级为纯官方 Web UI），但这**只覆盖启动期**，不覆盖运行期的静默死亡。

**何时必须解决**
W1 上线前。这不是后续波次的问题，是现在就能咬到用户的问题。

**倾向的解法**
控制通道加一条 `surface/ping` ↔ `surface/pong`（10s 间隔，2 次未回即判定 client 半失联）。失联后的动作要和崩溃退位对齐：**撤下所有原生插槽视图，让官方 Web UI 接管**（如果 Web 侧真的死了，官方 UI 也不会动，但至少用户看到的是一个明显坏掉的界面，而不是一个看起来正常却点不动的界面）。

同时应该把「原生视图可交互但控制通道失联」这个状态**显式画出来**（灰化 + 提示），而不是静默失效。

---

## 三条缺口的共同点

它们都指向同一个判断偏差：**我在设计时把 overlay 和「父原生 / 子 Web」这类混合形态想得太可行了。**

实现暴露出来的规律是：

> **混合形态的成本远高于整块撤离。** 每一次「先做一半」的过渡态，都需要额外的协议字段、额外的失效判定、额外的降级路径。

所以三条缺口的倾向解法惊人地一致 —— **都是取消过渡态、直接跳终态**：

- G-1 → 不做 overlay 过渡，W4 直接整块撤离 composer；
- G-2 → 不做「父原生子 Web」，父槽接管必须自下而上；
- G-3 → 不做「半死不活」，控制通道失联即整体回落官方 UI。

这条规律应该反写进 [ARCHITECTURE.md §4](../ARCHITECTURE.md)：**evacuated 是唯一的一等落位，overlay 不是「另一种选择」而是「例外」，且每个 overlay 都必须有明确的消失计划。**

---

## 待办

- [ ] G-3：加 `surface/ping`/`pong` 与运行期失联降级（**W1 上线前**）
- [ ] G-2：把「父槽接管必须自下而上」写成 manifest 第 7 条规则并在 `manifest.ts` 强制（W7 前，但建议现在就加，成本低）
- [ ] G-1：W4 规划时确认取消 `input.*` 的 overlay 过渡态，直接整块撤离 composer
- [ ] 把「evacuated 是唯一一等落位」的结论反写进 ARCHITECTURE.md §4
