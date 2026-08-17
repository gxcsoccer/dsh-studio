# Architecture

DSH Studio 是官方 DeepSeek Harness 上面的一层 **bundle + profile + 原生宿主**。
它不实现 Agent 循环，不 vendor `dsh`，不 fork [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

这一版架构围绕一件具体的事情组织：**以插槽为单位，把官方 Web UI 逐个换成 SwiftUI，直到 WebView 可以被拿掉。**

This document only uses extension points published by DeepSeek Harness. If an API is not in the official source, it is not an extension point we depend on.

官方参考：

- [DeepSeek Harness Architecture](https://deepseek-harness.github.io/deepseek-harness/en/reference/)
- [Cordis Primer](https://deepseek-harness.github.io/deepseek-harness/en/reference/cordis-primer)
- [Plugins and lifecycle](https://deepseek-harness.github.io/deepseek-harness/en/develop/framework/)

---

## 0. 一句话架构 / The thesis

> 官方 UI 已经是一张 **具名插槽表**。迁移不是「盖住网页」，而是**在同一个插槽上以更低的 priority 注册我们自己的条目**，把该插槽的渲染权正当地赢过来；官方实现留在原地，成为自动回落。

因此：

- **迁移单位 = 一个插槽**（slot），不是「一块像素区域」。
- **每个插槽的状态是可配置的**（`web` / `mirrored` / `native` / `retired`），可以随时切回。
- **领域数据永不经过 WebView**。WebView 上的通道只承载「插槽编排」。
- 终局：当 `root` 插槽也原生化后，删掉 WebView **不需要改动任何一条原生数据路径**。

这三条决定了下面所有细节。反面教材与取舍见 [docs/adr/](./docs/adr/)。

---

## 1. Layers

```
┌──────────────────────────────────────────────────────────────────────┐
│  Native shell — SwiftUI (macOS first)                                │
│  窗口 · 菜单 · 钥匙串 · 通知 · 文件对话框 · 原生插槽视图              │
│                                                                      │
│   ├── NativeSlotHost      按插槽名装配 SwiftUI 视图                   │
│   └── StudioClient        领域数据的唯一来源（← loopback，不经 WebView）│
└───────▲───────────────────────────────────────▲──────────────────────┘
        │  ① 控制通道（编排）                    │  ② 数据通道（领域）
        │  WKScriptMessageHandler "studio"       │  loopback 127.0.0.1
        │  slot/mount · slot/props · intent      │  sessions · events · rpc
┌───────┴────────────────────────┐    ┌─────────┴──────────────────────┐
│  dsh-studio-client             │    │  dsh-studio-surface            │
│  (Cordis **client** plugin,    │    │  (Cordis **host** plugin,      │
│   跑在 WKWebView 里)            │    │   跑在 dsh 进程里)              │
│                                │    │                                │
│  ctx.slots.register(…, {       │    │  apply(ctx) · inject · Config   │
│    priority: -1 })  ← 遮蔽官方  │    │  ctx.effect() 开/关 loopback    │
│  NativeSlotProxy 组件           │    │  ctx.on('session/event', …)     │
│  只做编排，不搬运领域数据        │    │  ctx.agents · apiproxy 转发     │
└───────▲────────────────────────┘    └─────────▲──────────────────────┘
        │  官方 client 插件树                     │  官方 host 插件树
┌───────┴─────────────────────────────────────────┴──────────────────────┐
│  Official dsh runtime（不 fork）                                        │
│  Cordis kernel + dsh-base + ui-* client plugins + apiproxy              │
│  sessions · tools · llm · agent loop · sandbox · storage · ctx.slots    │
└────────────────────────────────────────────────────────────────────────┘
```

注意两个插件是**两半**，不是两个产品：

| | `dsh-studio-surface`（host 半） | `dsh-studio-client`（client 半） |
| --- | --- | --- |
| 进程 | `dsh` Node 进程 | WKWebView 内 |
| 职责 | 开 loopback 桥、投影会话/事件、转发 apiproxy | 在插槽上注册遮蔽条目、上报几何与 props |
| 生命周期 | `apply(ctx)` + `ctx.effect` | `apply(ctx)` + `ctx.effect` |
| 被谁消费 | 原生宿主的**数据**路径 | 原生宿主的**编排**路径 |
| 终局 | 保留（它就是原生端的后端） | 随 WebView 一起消失 |

**client 半是一次性脚手架，host 半是长期资产。** 所以任何「以后还要用」的东西都不许放在 client 半。

---

## 2. 官方插槽机制（我们唯一依赖的接缝）

以下全部来自官方源码 `packages/client/ui-slots/`，不是推测。

### 2.1 注册与遮蔽

```ts
// @deepseek-ai/dsh-client-ui-slots
ctx.slots.register(options, Component): () => void
```

- 一个插槽由 `SlotMap` 通过 **declaration merging** 声明，所有者用一次 `register` 同时贡献组件、声明子插槽、并给出注入面。
- 插槽有两个轴：
  - `kind: 'single' | 'list' | 'keyed' | 'chain'`
  - `scope: 'root' | 'session-maybe' | 'session'`
- **`priority` 升序，最小者渲染**（默认 `0`）。同一个 cell 上以**相同** priority 再注册会抛错并指名当前占有者；**不同** priority 即构成遮蔽。

> 原文（`ui-slots/src/index.ts`）：
> *"Cell shadowing rank (ascending, default 0, lowest renders; same key + same priority throws … register at a different priority to shadow it (lowest renders)"*

于是「把官方某块 UI 换成我们的」就是一行：

```ts
ctx.effect(() => ctx.slots.register(
  { name: 'sidebar', priority: -1 },   // 官方 ui-sidebar 用默认 0
  NativeSlotProxy('sidebar'),
), 'studio: shadow sidebar')
```

**官方组件仍然注册在 priority 0 上，没有被卸载。** 这不是副作用，这是设计：它是我们的回落。

### 2.2 崩溃退位 = 免费的降级通道

`SlotCore.entriesOfSlot` 取的是每个 cell 在 priority 序里**第一个「活着（non-abdicated）」的条目**。而 `reportEntryError(key, entry, error, { abdicate: true })` 会把崩掉的条目从 cell 里**退位**，`onEntryError` 被官方注释为 *"the supervision seam for hosts"*。

含义很重要：**我们的原生代理条目一旦渲染期崩溃，官方 Web 实现会自动接管这一格。** 增量迁移最怕的「换了一半、用户卡死」，上游已经给了机制。我们只需要：

1. 把 `onEntryError` 接到宿主遥测；
2. 崩溃即上报 + 记账，不吞掉。

### 2.3 client 插件如何被装载

- 每个 client 插件在 `package.json` 里声明 `dsh.client.inject` 与 `platform: "web"`，从 `./client` 导出 `inject` 数组与 `apply(ctx)`。
- Web 壳启动时解析 `window.__DSH_BOOT__` 成 `BootManifest`，由 `ClientModuleSystem` 逐行 fetch 插件 bundle，再交给 vendored cordis `Loader` 为每一行建一个 entry。
- 也就是说：**只要我们的 bundle 进了 host 的插件图，它的 client 半就会被自动 fetch 并 apply。** 不需要注入 `<script>`，不需要改官方页面。

这条链路是 `cordis.patch.yml` → host 插件图 → BootManifest → client entry。我们只往第一环写东西。

---

## 3. 插槽全图与迁移单位

官方在 `renderSlot()` 调用点上实际使用的插槽（完整清单与属性见 [docs/slot-map.md](./docs/slot-map.md)）：

| 层 | 插槽 | kind |
| --- | --- | --- |
| 根 | `root` | single |
| 骨架 | `sidebar` · `conversation` · `details` · `shell.overlay` | single/list |
| 侧栏 | `sidebar.workspaces` · `sidebar.settings` · `sidebar.footer.action` · `sidebar.workspaces.directoryFlow` | single/list |
| 会话 | `conversation.session` · `conversation.session.header` · `.header.actions` · `.header.utilities` · `conversation.view` | single/list |
| 输入 | **`conversation.composer`（chain，官方明写 takeover）** · `conversation.composer.bar` · `.composer.dock` · `conversation.input.dock` · `.input.left` · `.input.right` · `.input.model` · `.input.plan` · `.input.overlay` | chain/single/list |
| 消息 | **`conversation.chat.node`（keyed by ChatNodeKind）** · `.chat.commandview` · `.chat.turnTail` · `.chat.assistant-actions` | keyed/chain/list |
| 工具 | **`tool.call.toolview`（keyed by tool）** | keyed |
| 空态 | `conversation.hero.workspace` · `.hero.agentPreset` · `.hero.workspace.directoryFlow` | single |
| 设置 | `settings.trigger` · `.header` · `.action` · `.close` · `.section` · `.plugins.tab` · `.plugin.item` · `.onboarding` · `.general.item` | single/list |

三个加粗的插槽值得单独说：

- `conversation.composer` 是 **chain** 型，官方注释直接写 *"The composer takeover chain: entries are selector-routed replacements"* —— 换输入框是官方预留动作，不是 hack。
- `conversation.chat.node` 是 **keyed**（key = `ChatNodeKind`），意味着可以**只把某一种消息卡片**换成原生，其余种类继续走 Web。迁移粒度可以细到单个消息类型。
- `tool.call.toolview` 同理按工具种类分格。

这直接推翻了「粒度只能到整列」的判断：**粒度可以到「一种消息卡片」。**

---

## 4. 两种落位方式：evacuated 与 overlay

原生视图和 Web 布局的关系只有两种，必须在每个插槽上显式选一种。

### 4.1 Evacuated（撤离式，**默认，优先**）

该插槽整块**离开 Web 布局**，搬到原生 chrome 里占真实屏幕面积。Web 侧的代理组件渲染成零尺寸/不占位。

```
┌─ NSWindow ───────────────────────────────┐
│ ┌ SwiftUI Sidebar ┐┌ WKWebView ────────┐ │
│ │  (原生真身)      ││  官方 conversation │ │
│ │                 ││                   │ │
│ └─────────────────┘└───────────────────┘ │
└──────────────────────────────────────────┘
        ↑ 插槽在 Web 里渲染为 0 尺寸
```

适用：`sidebar*`、`details`、`settings.*`、`root`。
优点：没有坐标同步、没有滚动同步、没有点击穿透问题。**能撤离就撤离。**

### 4.2 Overlay（覆盖式，**受限使用**）

原生视图按 Web 上报的 rect 悬浮在 WebView 之上。Web 侧代理组件渲染一个等尺寸的透明占位来撑住布局。

适用：只在插槽必须留在 Web 排版流里时使用，例如 `conversation.input.model`、`conversation.input.plan` 这类嵌在工具行里的小控件。

**硬规则：滚动容器内部不许 overlay。** `conversation.chat.node` 在转录滚动区里，逐节点 overlay 会掉帧、错位、撕裂。遇到这种情况**向上升级到最近的可撤离祖先**（即整块 `conversation.view` 一次性原生化，从事件流自己渲染转录）。详见 [ADR-0003](./docs/adr/0003-no-overlay-inside-scroll-containers.md)。

---

## 5. 插槽状态机与 surface manifest

每个插槽在任意时刻处于四态之一：

```
  web ──▶ mirrored ──▶ native ──▶ retired
   ▲          │           │
   └──────────┴───────────┘   任意时刻可回退
```

| 态 | 含义 | 谁渲染 |
| --- | --- | --- |
| `web` | 尚未开工 | 官方（priority 0） |
| `mirrored` | 原生实现已存在，但隐藏运行，仅用于对照/截图 diff | 官方 |
| `native` | 我们以 `priority: -1` 遮蔽，原生接管 | 我们 |
| `retired` | 已稳定，官方实现对本产品不再有意义（仍留作回落） | 我们 |

这张表就是配置：

```yaml
# studio profile 的 config，Schemastery 校验
surface:
  sidebar:              { mode: native,   placement: evacuated }
  sidebar.workspaces:   { mode: native,   placement: evacuated }
  conversation.composer:{ mode: mirrored, placement: evacuated }
  conversation.view:    { mode: web }
  tool.call.toolview:
    keys:
      read:  { mode: native, placement: evacuated }
      write: { mode: web }
```

三个后果，都是这套设计的主要收益：

1. **可回退**：线上出问题，改一行 config，官方 UI 立刻回来，不用发版。
2. **可对照**：`mirrored` 让原生实现能在真实数据上跑而不影响用户；截图 diff 进 CI。
3. **用户可覆盖**：官方 patch 规则是「按 id 瞄准一行并整份替换 config」，所以用户能在自己的 profile patch 里把任何插槽掰回 Web，不用改我们的源码。

manifest 的 schema 与解析规则见 [docs/surface-manifest.md](./docs/surface-manifest.md)。

---

## 6. 两条通道（这是与旧方案最大的分歧）

### 6.1 控制通道 — 只走编排

- 传输：`WKScriptMessageHandler`（Web→Native）+ `evaluateJavaScript`（Native→Web）
- 载荷：**只有插槽编排**。插槽挂载/卸载、props 快照、几何 rect、以及用户在原生视图上产生的 intent。
- 不承载：会话列表、消息内容、事件流、任何领域实体。

### 6.2 数据通道 — 领域数据的唯一路径

- 传输：`127.0.0.1` loopback，由 `dsh-studio-surface` 在 `ctx.effect()` 里开、卸载时关。永不绑 `0.0.0.0`。
- 载荷：sessions / workspaces / `session/event` 流 / apiproxy RPC 转发。
- 原生宿主的 `StudioClient` 是这条通道的客户端，**它不知道 WebView 存在**。

为什么必须分开：领域数据一旦借道 WebView，WebView 就成了产品的关键路径 —— 它一崩，原生侧连会话列表都拿不到；而且等到终局要删 WebView 时，所有数据路径都得重写。分开之后，**删 WebView 是删掉一条编排通道，而不是动一次心脏手术。**

协议、方法表、错误与超时语义见 [docs/bridge-contract.md](./docs/bridge-contract.md)。

---

## 7. 契约代码生成与漂移检测

上游是 developer preview，会破坏性变更。两道防线：

1. **Swift 契约生成**：从官方 `packages/host/apiproxy` 的 schema 与 `RpcMethodMap` 生成 `DSHKit/Generated/`。所有 tagged union 生成带 `case unknown(JSONValue)` 的枚举 —— 上游加一个变体不会让原生端崩。
2. **插槽契约漂移检测**：把「插槽名 + kind + scope + props 形状」的快照存进仓库，CI 比对；上游改了插槽表就**大声失败**，而不是等运行时白屏。

TS 侧还有一层免费保险：插槽是 declaration merging 出来的类型，上游改了 props，我们的 client 半**编译期**就红。

---

## 8. 迁移波次

顺序按「风险 × 收益」排，逐波推进，每波都必须能独立发布。完整逐插槽表与验收门见 [docs/slot-map.md](./docs/slot-map.md) 与 [docs/migration-playbook.md](./docs/migration-playbook.md)。

| 波 | 目标 | 落位 | 为什么排这个位置 |
| --- | --- | --- | --- |
| **W1** | `sidebar` + 三个子插槽 | evacuated | 纯导航，无流式内容；原生收益立刻可见（列表密度、键盘、拖拽）；失败面小 |
| **W2** | `settings.*`、`details` | evacuated | 表单与面板最适合原生控件；与消息流解耦 |
| **W3** | `conversation.session.header`、`shell.overlay` | evacuated | 会话框架层，为 W4 腾出原生 chrome |
| **W4** | `conversation.composer`（chain takeover）+ `input.*` | evacuated / 少量 overlay | 官方预留 takeover；输入法、快捷键、拖拽附件是原生强项 |
| **W5** | `conversation.view` 整块（含转录渲染） | evacuated | 最难：要从 `session/event` 自己渲染流式转录。**不做逐节点 overlay** |
| **W6** | `tool.call.toolview` / `chat.node` 按 key 收尾 | evacuated | 到这一步已在原生转录里，按种类补齐 |
| **W7** | `root` | evacuated | 最后一格。WebView 不再渲染任何 UI |
| **W8** | 拆除 client 半与 WebView | — | 数据路径零改动（见 §6） |

W7 结束时，Web 侧只剩一个不渲染东西的 cordis 插件；W8 是删代码，不是重写。

---

## 9. Profile `studio`

```
empty root
  1. @deepseek-ai/dsh-base            # official first layer
  2. 官方 client ui-* 插件树            # 保留！它们是回落
  3. dsh-studio-surface (host)        # loopback 桥 + 事件投影
  4. dsh-studio-client (client)       # 插槽遮蔽（一次性脚手架）
  5. profile cordis.patch.yml         # 用户覆盖：可把任意插槽掰回 web
  6. home-level cordis.patch.yml
  7. --patch overlay
```

与旧方案的关键差异在第 2 层：**我们不再试图把官方 UI 插件从图里拿掉。** 它们留着，成本是一点内存，收益是随时可回退 + 崩溃自动接管。

验证真实启动的树：

```sh
dsh --profile studio --dump-config
```

---

## 10. Extension points（published only）

依赖的官方接缝，全部有源码依据：

| 接缝 | 用途 | 依据 |
| --- | --- | --- |
| `apply(ctx)` | 两个半插件的唯一入口 | Cordis 插件契约 |
| `inject` | 声明硬依赖服务（`slots` / `sessions` / `workspaces` / `agents`） | `ui-sidebar` 等官方插件同款 |
| `Config` / Schemastery | surface manifest 的校验与默认值 | 官方教程 |
| `ctx.effect` | 桥 socket、监听、插槽注册的可逆注册 | 官方生命周期 |
| `ctx.slots.register` | **插槽遮蔽（本架构核心）** | `ui-slots/src/index.ts` |
| `ctx.slots.onEntryError` | 崩溃退位遥测 | 同上，官方注为 host 监管缝 |
| `session/event` | 会话事实的唯一权威来源 | 官方：Model-visible means logged |
| `ctx.agents` | 创建/恢复/注入/取消 | 官方对照表：*Add UI → drive `ctx.agents`* |
| apiproxy `RpcMethodMap` | Swift 契约生成源头 | `packages/host/apiproxy` |

不发明未公开的 API；不依赖类名哈希；不依赖 DOM 结构。

---

## 11. What we will not do

- ❌ **不用 CSS 隐藏官方 UI**。不写 `grid-template-columns: 0px`，不写 `[class*="_sidebarCol"]` 这类哈希类名通配选择器。插槽 priority 是官方接缝，CSS 猜类名不是。见 [ADR-0001](./docs/adr/0001-slot-shadowing-over-css-hiding.md)。
- ❌ **不让领域数据穿过 WebView**。见 [ADR-0002](./docs/adr/0002-domain-data-bypasses-the-webview.md)。
- ❌ **不在滚动容器里做 overlay**。见 [ADR-0003](./docs/adr/0003-no-overlay-inside-scroll-containers.md)。
- ❌ **不卸载官方 UI 插件**。它们是回落与对照。见 [ADR-0004](./docs/adr/0004-keep-official-ui-as-fallback.md)。
- ❌ 不 fork `deepseek-ai/deepseek-harness`，不改上游源码，不把提 PR 当产品前提。
- ❌ 不从 Electron 起步；Mac 是 SwiftUI，Win/Linux 后续用 Tauri 复用同一份 §6 契约。
- ❌ 不做官方 Web UI 的 iframe 壳。

---

## 12. Repository layout（本设计的目标形态）

```
apps/macos/                     # SwiftUI 宿主
  Sources/DSHKit/               #   契约（含 Generated/）
  Sources/DSHKit/Generated/     #   由 apiproxy schema 生成
  Sources/DSHClient/            #   loopback 数据通道客户端（不认识 WebView）
  Sources/DSHSurface/           #   控制通道 + NativeSlotHost
  Sources/DSHApp/               #   窗口/菜单/通知 + 各插槽的原生视图
packages/studio-surface/        # Cordis host 插件（长期资产）
packages/studio-client/         # Cordis client 插件（一次性脚手架）
  src/client/native-slot.tsx    #   NativeSlotProxy：唯一的通用代理组件
  src/client/manifest.ts        #   读 surface manifest → 决定注册哪些遮蔽
tools/schema-codegen/           # apiproxy schema → Swift
tools/slot-snapshot/            # 插槽契约漂移检测
docs/                           # 本设计的其余部分
```

---

## 13. 这份设计相对现有分支的取舍

现有两条分支各有值得继承的东西，也各有本设计明确不走的路。

**继承**（来自 `codex/agent-sidebar`）：

1. 从上游 schema 生成 Swift 契约，union 带 `unknown` 回落；
2. 录制真实流量做契约测试，而不是自己对自己断言；
3. loopback-only 的桥，生命周期绑 `ctx.effect`；
4. 「切工作区不重启 runtime」「会话卡死要有出口」这两个工程教训。

**继承**（来自 `cursor/design-playground-a785`）：

5. 主题 token 单一来源 + 注入 WebView，让混合期视觉不割裂（混合期必需品）；
6. playground 沉淀的视觉结论（Graphite × Console、品牌蓝只出现在模型正在动的地方）。

**不走的路**：

- 用 CSS + MutationObserver 抹掉官方侧栏 → 换成插槽 priority 遮蔽（§2.1）；
- 把会话目录投影经由 Web 通道送给原生 → 换成 loopback 数据通道（§6）；
- 「不叠官方 UI 插件、自建 roster」→ 改为**保留**官方插件作回落（§9、ADR-0004）；
- 一次性大重写 → 改为按插槽状态机推进的可回退波次（§5、§8）。
