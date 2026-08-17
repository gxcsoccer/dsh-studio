# Bridge Contract — 桥接契约

桥是 **DSH Studio 的产品表面，不是 DeepSeek 的公共 API**。它存在的唯一理由：让原生进程和 Cordis 进程解耦，同时把官方扩展点全部留在 `dsh` 进程内。

本文件冻结第一版契约。两端（SwiftUI 宿主、后续 Tauri 宿主）共用它；桥稳定，壳可以换。

---

## 0. 两条通道，职责不可混用

```
                     ┌──────────────────────────────┐
                     │      SwiftUI Host            │
                     │  ┌────────────┐ ┌──────────┐ │
                     │  │DSHSurface  │ │DSHClient │ │
                     │  │(编排)       │ │(领域)     │ │
                     │  └─────▲──────┘ └────▲─────┘ │
                     └────────┼─────────────┼───────┘
        ① 控制通道 Control     │             │  ② 数据通道 Data
        WKScriptMessageHandler │             │  HTTP + SSE over 127.0.0.1
        + evaluateJavaScript   │             │
                     ┌─────────┴──────┐ ┌────┴──────────────┐
                     │ studio-client  │ │ studio-surface    │
                     │ (WebView 内)    │ │ (dsh 进程内)       │
                     └────────────────┘ └───────────────────┘
```

| | ① 控制通道 | ② 数据通道 |
| --- | --- | --- |
| 传输 | `WKScriptMessageHandler` / `evaluateJavaScript` | `127.0.0.1` HTTP + SSE |
| 对端 | `studio-client`（Cordis client 插件） | `studio-surface`（Cordis host 插件） |
| 载荷 | **只有插槽编排**：挂载、props、几何、intent | **只有领域数据**：会话、事件流、RPC |
| 可靠性要求 | 可丢、可重放（UI 编排是幂等的） | 不可丢（会话事实） |
| 终局 | 随 WebView 删除 | 长期保留，成为原生端的后端 |

**硬约束：控制通道不许出现任何领域实体。** 不许传会话列表、不许传消息内容、不许传事件流。判据很简单 —— *这条数据在 WebView 被删除后还需要吗？需要，就走数据通道。* 理由见 [ADR-0002](./adr/0002-domain-data-bypasses-the-webview.md)。

---

## 1. 控制通道

### 1.1 传输与握手

- Native → Web：`webView.evaluateJavaScript("window.__DSH_STUDIO__.receive(<json>)")`
- Web → Native：`window.webkit.messageHandlers.studio.postMessage(<json>)`
- `studio-client` 在 `apply(ctx)` 里通过 `ctx.effect()` 挂 `window.__DSH_STUDIO__`，插件卸载时摘掉。

握手是**由 Web 侧发起**的，因为 client 插件的加载时机由 `BootManifest` 决定，宿主无法预知：

```
Web  → Native   { v:1, t:"evt", m:"surface/ready", p:{ protocol:1, slots:[...] } }
Native → Web    { v:1, t:"req", m:"surface/configure", id:"…", p:{ manifest:{…} } }
Web  → Native   { v:1, t:"res", id:"…", ok:true, p:{ applied:[...], rejected:[...] } }
```

`surface/ready` 里的 `slots` 是 client 插件**实测到的**官方插槽清单（`kind`/`scope`/当前占有者），宿主拿它和自己编译期的快照比对 —— 这是运行时的漂移检测，比 CI 快照更贴近真实机器。

宿主在收到 `surface/ready` 前不渲染任何原生插槽视图，只显示启动态。15s 未收到 → 判定 client 半未加载，进入「纯官方 Web UI」降级模式并上报。

### 1.2 信封

所有消息共用一个信封，四种类型：

```jsonc
// req — 需要回执
{ "v": 1, "t": "req", "id": "01J…ULID", "m": "slot/invoke", "p": { … } }
// res — 回执（成功）
{ "v": 1, "t": "res", "id": "01J…ULID", "ok": true, "p": { … } }
// res — 回执（失败）
{ "v": 1, "t": "res", "id": "01J…ULID", "ok": false,
  "e": { "code": "slot_not_mounted", "message": "…", "retryable": false } }
// evt — 单向通知，无回执
{ "v": 1, "t": "evt", "m": "slot/rect", "p": { … } }
```

| 字段 | 说明 |
| --- | --- |
| `v` | 协议版本，当前 `1`。收到未知 `v` → 拒绝并降级到纯 Web，不猜。 |
| `t` | `req` / `res` / `evt` |
| `id` | ULID，仅 `req`/`res`。单调递增便于排序调试 |
| `m` | 方法名，`<域>/<动作>` |
| `p` | payload |
| `e` | 错误，仅 `ok:false` |

### 1.3 方法表

#### Native → Web（req）

| 方法 | payload | 语义 |
| --- | --- | --- |
| `surface/configure` | `{ manifest }` | 下发 surface manifest，client 据此决定注册哪些遮蔽条目 |
| `surface/reconfigure` | `{ patch }` | 运行时改单个插槽的 `mode`，用于对照与热回退（**不重启，不刷新页面**） |
| `surface/ping` | `{ seq, sentAt }` | 运行期活体探测（§1.6）。**宿主是发起方**，10s 一拍；`seq` 单调递增，`sentAt` 是宿主时钟（epoch 秒）。client 必须回执 `{ seq, sentAt }`（原样回抄），回执本身就是活体证据 |
| `slot/invoke` | `{ slot, instanceId, action, args }` | 原生视图上的用户动作回灌到 Web 侧的注入面（例如点原生侧栏的「新会话」→ 调 `ctx.workspaces.startSession`） |
| `slot/probe` | `{ slot }` | 查询某插槽当前占有者与 priority，用于诊断 |

#### Web → Native（evt）

| 方法 | payload | 语义 |
| --- | --- | --- |
| `surface/ready` | `{ protocol, slots[] }` | 握手 |
| `surface/pong` | `{ seq }` | `surface/ping` 的**等价单向形式**（§1.6）。宿主两种形态都算活体证据；client 半在两拍之间想主动证明自己还活着时用它，不必发明新方法 |
| `slot/mount` | `{ slot, instanceId, key?, scope, props }` | 一个遮蔽条目被渲染了，原生该装配对应视图 |
| `slot/props` | `{ instanceId, props }` | props 变化（已做浅 diff，只发变化字段） |
| `slot/rect` | `{ instanceId, rect, clip, viewport, scrollable, occluded, dpr }` | 几何上报，**仅 overlay 落位需要**（字段见 §1.7） |
| `slot/unmount` | `{ instanceId }` | 条目卸载，原生该回收视图 |
| `slot/error` | `{ slot, instanceId, error, abdicated }` | 来自 `ctx.slots.onEntryError`：我们的条目崩了；`abdicated:true` 表示官方实现已自动接管 |

`slot/error` 是这条通道上最重要的一条消息 —— 它把官方的崩溃退位机制接到宿主遥测，让「悄悄回落」变成「记账的回落」。

### 1.4 instanceId 与生命周期

`instanceId` 由 Web 侧生成（ULID），一个插槽在 `keyed`/`list` 下可以同时存在多个实例，所以**原生视图与 `instanceId` 一一对应，而不是与 slot 名对应**。

宿主必须容忍：`slot/props` 早于 `slot/mount` 到达（丢弃）、`slot/unmount` 后仍收到 `slot/props`（丢弃）、同一 `instanceId` 重复 `mount`（视为 props 刷新）。控制通道是幂等编排，不做事务。

### 1.5 超时与错误

- `req` 默认超时 **5s**（`surface/configure` 15s）。超时 → 抛错 + 上报，**不重试**（重试编排会造成重复挂载）。
- 错误码是封闭集合：`unknown_method` / `bad_payload` / `protocol_mismatch` / `slot_not_declared` / `slot_not_mounted` / `priority_conflict` / `internal`。
- `priority_conflict` 专指官方 `register` 在同 cell 同 priority 抛错的情况（官方会指名占有者）。这条错误必须**大声失败**：它意味着上游或另一个插件也占了我们的 priority，配置需要人来决策，不能自动挪位。

### 1.6 心跳与运行期失联（G-3）

握手 watchdog 只覆盖启动期。运行期 client 半可能**静默死亡**（JS 异常卡住事件循环、页面被系统回收而 WKWebView 实例仍在），此时原生插槽视图还在显示，但 `slot/invoke` 全部无效 —— **用户点得到、点了没反应**，比白屏更糟。

因此心跳的方向不是对称的，**宿主是发起方**：

```jsonc
// Native → Web，每 10s 一拍
{ "v":1, "t":"req", "id":"01J…", "m":"surface/ping", "p":{ "seq":7, "sentAt":1755000000 } }
// Web → Native，主格式：普通回执（回执本身就是活体证据）
{ "v":1, "t":"res", "id":"01J…", "ok":true, "p":{ "seq":7, "sentAt":1755000000 } }
// Web → Native，等价单向形式（宿主同样认）
{ "v":1, "t":"evt", "m":"surface/pong", "p":{ "seq":7 } }
```

| 项 | 值 | 依据 |
| --- | --- | --- |
| 发起方 | 宿主（native），client 半只回答 | 只有监督方能发现对端静默死亡；死掉的事件循环无法自我上报 |
| 间隔 | 10s | `SurfaceHeartbeat.interval` |
| 判死阈值 | 连续 2 拍无任何回应 | `SurfaceHeartbeat.missThreshold` |
| 丢 1 拍 | `suspect` 态：宿主把原生插槽**置灰禁用**，并显示提示 | 「可交互但通道失联」必须画出来，不许静默失效 |
| 判死动作 | **撤下所有原生插槽视图，官方 Web UI 接管**（与崩溃退位对齐，ADR-0004） | 判死后不自动复活：自动回摆会让界面在两种实现之间抖动 |

client 半的义务只有一条：**`surface/ping` 的处理器必须在插件整个生命周期内保持安装**。未安装的处理器会回 `unknown_method`，宿主把它读成一次丢拍 —— 两拍即判死。`seq` 原样回抄，宿主用它识别「对端在回旧拍」（`staleReplyCount`）。

---

### 1.7 slot/rect 的几何（overlay 的落位契约）

`overlay` 的语义是「**Web 侧留出这一格，原生视图精确填进去**」。要做到「精确」，宿主必须能回答三个问题，而第一版 `{ rect, scrollable }` 只能回答第一个：

| 字段 | 类型 | 回答的问题 |
| --- | --- | --- |
| `rect` | `{x,y,w,h}` | 这一格在哪。`getBoundingClientRect()`，CSS px、视口坐标，已含祖先滚动 |
| `clip` | `{x,y,w,h}` | **我能画到多远。** 祖先 `overflow` 裁剪链 ∩ 视口。没有裁剪祖先时等于视口 |
| `viewport` | `{w,h}` | **CSS px 与 point 的比例是多少。** 宿主用 `WebView 点宽 / viewport.w` 求解 |
| `scrollable` | boolean | 是否在**滚动**容器内（ADR-0003 的判据）。必填，宿主不给默认值 |
| `occluded` | boolean | **我现在该不该画。** 这一格是否被 Web 侧内容完整盖住 |
| `dpr` | number | 仅诊断。`devicePixelRatio` 是点→物理像素，**不是**本换算的系数 |

三条硬规则：

1. **`clip` ≠ `scrollable`。** `overflow: hidden` 只裁剪、不滚动，不构成 ADR-0003 的漂移源（内容不会在合成线程上独立移动）。把两者当成一个 bit，就只剩两个错答案：按 ADR-0003 拒掉这一格（原生视图永不出现），或者让它在折叠动画期间溢出到相邻区域上。W1 的目标插槽正好住在官方侧栏 `overflow: hidden` 的区域里，所以这不是理论问题。
2. **比例来自 `viewport`，不是 `dpr`。** 视网膜下 `dpr = 2` 而 CSS px 与 point 恒为 1:1；拿 `dpr` 当系数的症状是原生视图正好大一倍。`pageZoom`、`<meta viewport>` 缩放全部被 `WebView 点宽 / viewport.w` 这一个比值吸收。
3. **`occluded` 的方向是「不知道就保持可见」。** 无法判定（拿不到 `elementFromPoint`）时报 `false`：一个可能被浮层压住的原生视图，比一块凭空消失的 UI 容易发现得多。判定只在**完整**覆盖时为真 —— 部分覆盖交给 `clip` 与宿主的 mask。

宿主侧的换算是纯函数（`SlotGeometryResolver`），`frame` 与 `visibleFrame` 分开：视图按完整 `frame` **布局**（否则文字会按被裁短的宽度换行），按 `visibleFrame` **呈现**。被完整遮挡或裁到零面积时整块不渲染。

上报时机：`ResizeObserver`（格子自身变化）、`resize`（窗口）、`scroll`（capture，祖先滚动）。**几何不变则不发** —— 这三个源每帧都会触发，把没变的矩形也发上线等于给控制通道灌噪声。

---

## 2. 数据通道

### 2.1 绑定与生命周期

- 只绑 `127.0.0.1`，**永不 `0.0.0.0`**。端口来自 `Config`，默认 `43180`，占用则失败退出而不是自动换端口（换端口会让宿主找不到）。
- 在 `apply(ctx)` 中用 `ctx.effect(() => { const srv = listen(); return () => srv.close() })` 开启；插件卸载 / profile 热替换时端口必须干净归还。
- 认证：启动时生成一次性 token 写入 `$DSH_HOME/studio/bridge.json`（`0600`），宿主读文件取 token，每个请求带 `Authorization: Bearer`。loopback 也要认证 —— 同机其他进程不该能驱动用户的 agent。

**握手文件字段表**（`$DSH_HOME/studio/bridge.json`，`studio-surface` 写、宿主读）。这张表原本缺失，宿主侧因此只能自己猜一套字段名（`BridgeDescriptor.swift` 里标了「契约缺口」）—— 猜错的代价是「runtime offline」而没有任何诊断信息，所以现在钉死在这里：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `host` | string | 绑定地址，恒为 `127.0.0.1`（代码断言，不是配置项，见 §5）。宿主对非 loopback 值**拒绝连接** |
| `port` | number | 数据通道端口，默认 `43180` |
| `origin` | string | `http://<host>:<port>`，同一信息的预拼形式 |
| `token` | string | 一次性 Bearer token（256 bit hex）。缺失或为空 → 宿主拒绝以未认证方式通信 |
| `protocol` | number | 控制通道协议版本，与 `surface/ready` 里的 `protocol` 同源（§1.2） |
| `pid` | number | 写文件的 dsh 进程号，仅用于诊断「文件是谁留下的」 |
| `webUrl` | string?（可选） | 官方 Web 壳地址，宿主 WKWebView 要加载的那一个。来自 `studio-surface` 的 `bridge.shellUrl` 配置；**未配置时整个字段不出现**（不是空串），宿主据此区分「还没发布」与「发布了一个空地址」，并退回自己的 `DSH_STUDIO_SHELL_URL` 环境变量 |

`webUrl` 是配置而不是插件自己推导的值：浏览器该用哪个地址由 web bundle 的 `webserver` 行、反向代理、SSH 隧道共同决定，只注入 `apiProxy` 的插件无从得知。写死一个 `127.0.0.1:3080` 默认值会让任何改了 bind 的运行**加载错误的页面**，那比没有地址更糟。

文件在 `listen` 成功之后才写、插件卸载时删除：指向没人监听的端口的握手文件比没有文件更坏。

### 2.2 面向原生的两类端点

**(a) RPC 转发** — 原生端的领域调用不自己发明语义，直接转发到官方 apiproxy：

```
POST /rpc   { "method": "session.prompt", "params": { … } }
```

`method` 取值域 = 官方 `RpcMethodMap`（`packages/host/apiproxy/src/api/rpc-map.ts`）。**我们不在这里加自己的方法**，加了就是在造一套影子 API，上游一改就全断。Studio 自己的少数需求（例如原生文件对话框结果回灌）走 `/studio/*` 前缀，与转发面严格分开。

**(b) 事件流** — `GET /events`（SSE），转发 `session/event` 与必要的 `agent/*`：

```
event: session
data: { "sessionId":"…", "seq":128, "event":{ … } }
```

语义对齐官方：**会话状态以 `session/event` 日志为准**。原生端只做投影缓存，不做第二份权威记录 —— 官方原则是 *Model-visible means logged*，能进模型请求的东西必须能从日志重建。

### 2.3 断线与重放

- SSE 断线：宿主用 `Last-Event-ID`（= `seq`）续传。
- 长时间断开（超过 surface 侧保留窗口）：宿主放弃增量，重新 `session.history` 拉全量快照再续流。
- 宿主必须能显示「与 runtime 失联」态。这是从 `codex/agent-sidebar` 分支继承的教训：断连横幅是第一个值得原生化的东西，因为 Web UI 断连时恰好也没法告诉你它断连了。

---

## 3. Swift 契约生成

生成的 Swift 类型是数据通道的唯一类型来源，手写副本一律禁止。

- 源头：官方 `packages/host/apiproxy` 的 schema 与 `RpcMethodMap` 接口。
- 产物：`apps/macos/Sources/DSHKit/Generated/`。
- 规则：所有 tagged union 生成带 **`case unknown(JSONValue)`** 的枚举；上游新增变体时原生端降级显示而不是崩溃。
- 校验：`tools/record-fixtures` 录制真实流量存进 `Tests/Fixtures/`，契约测试**拿录制流量做断言**，不是拿生成代码自己对自己断言。

后一条是从既有分支继承的关键纪律：自证的契约测试在上游变更时会一起变绿，等于没有测试。

---

## 4. 版本演进

- `v` 只在**不兼容**变更时递增。加方法、加可选字段不动 `v`。
- 宿主与 client 半的 `v` 不一致时：不猜、不适配，直接降级到纯官方 Web UI 并上报。混合期最怕的是「半懂协议」的两端把状态搞坏。
- 控制通道的方法表允许收缩（W7 之后大量方法会消失），这不算破坏性变更 —— 那时候 client 半正在被拆除。

---

## 5. 安全边界

| 事项 | 规则 |
| --- | --- |
| 绑定地址 | 仅 `127.0.0.1`，代码里硬断言，不给配置项 |
| 认证 | 一次性 token，`0600` 文件，Bearer 头 |
| 控制通道输入 | 来自 WebView 的消息**一律当不可信输入**校验（WebView 里跑着第三方插件代码） |
| `slot/invoke` | 只能触达 manifest 里声明为 `native` 的插槽的注入面，不能任意调用 `ctx` |
| 文件路径 | 原生文件对话框返回的路径经 `/studio/*` 回灌，由 surface 侧做工作区边界校验，不直接塞进 RPC |
| 日志 | 两条通道的 payload 默认不落盘；诊断模式下落盘需脱敏消息正文 |

第三行值得强调：WebView 里同时跑着官方与第三方 client 插件。控制通道的对端**不是一个可信的自己人**，是一个装着别人代码的沙箱。
