# Architecture

DSH Studio 是官方 DeepSeek Harness 上的一个 **carrier + host backends + client shape**。
它不实现 Agent 循环，不 vendor `dsh`，不 fork [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

在 harness 自己的世界观里，macOS 客户端不是「壳」，是**第四种 client shape**。官方 Web UI 只是碰巧是第一个。

This document only uses extension points published by DeepSeek Harness. If an API is not in the official docs or in the published type surface of an installed `@deepseek-ai/*` package, it is not an extension point we depend on.

官方参考：

- [DeepSeek Harness Architecture](https://deepseek-harness.github.io/deepseek-harness/en/reference/)
- [Cordis Primer](https://deepseek-harness.github.io/deepseek-harness/en/reference/cordis-primer)
- [Plugins and lifecycle](https://deepseek-harness.github.io/deepseek-harness/en/develop/framework/)
- 产品页：[deepseek.com/harness](https://deepseek.com/harness)

本机可验证：装过 `dsh` 之后，下面每一条契约都能在 `$DSH_HOME/profiles/node_modules/@deepseek-ai/*` 的 `README.md` 与 `lib/types/*.d.ts` 里读到原文。本文引用的行号会漂，包名和类型名不会。

---

## 0. TL;DR

三句话：

1. **别造桥，写 carrier。** `ctx.apiProxy` 是官方已发布的网关契约，明确写着 transport-agnostic、由 carrier 自己包。我们提供一根 Unix domain socket 的管子，不发明路由。
2. **别 iframe，组 roster。** 官方 UI 不是一个网页，是浏览器里的一棵 Cordis 插件树。我们自己列 roster、换掉 chrome 行、保留会话行，然后逐个 slot 原生化。
3. **别包壳，做后端插件。** Keychain、通知这类原生能力是 Service seam 的后端，按官方 dual-face 样板写，不是套在 `dsh` 外面的一层。

---

## 1. Layers

```
┌─────────────────────────────────────────────────────────────┐
│  DSH.app — client shape (Swift / SwiftUI)                   │
│  Swift port of AbstractApiClient                            │
│  windowing · menus · command palette · notifications        │
│  keychain UI · workspace bookmarks · first-run              │
└──────────────────────────▲──────────────────────────────────┘
                           │  unix domain socket (0600)
                           │  4-quadrant envelope + SSE
                           │  contract = official RpcMethodMap
┌──────────────────────────┴──────────────────────────────────┐
│  dsh-carrier-macos — carrier                                │
│  toFetchHandler(ctx.apiProxy) on a UDS. No business logic.  │
├─────────────────────────────────────────────────────────────┤
│  dsh-host-credentials-keychain — CredentialProvider backend │
│  dsh-host-notify-macos         — turn / approval notices    │
├─────────────────────────────────────────────────────────────┤
│  studio client roster — our own browser plugin rows         │
│  own layout: owns root, declares conversation, ctx.layout   │
│  + official ui-conversation and its downstream rows         │
└──────────────────────────▲──────────────────────────────────┘
                           │  official plugin tree
┌──────────────────────────┴──────────────────────────────────┐
│  Official dsh runtime                                       │
│  Cordis kernel + @deepseek-ai/dsh-base                      │
│  sessions · tools · llm · agent loop · sandbox · storage    │
└─────────────────────────────────────────────────────────────┘
```

**这张图是终点形态（M4）。** 在那之前，只要还有官方 `ui-*` 行在渲染，组合里就多一个 loopback TCP webserver，Swift 侧也就直接打官方 web carrier 而不是 UDS——client plane 硬依赖 `ctx.webServer`，理由见 [§4](#client-plane-硬依赖-ctxwebserver)，排期见 [§5](#5-roadmap)。图里的其它三个角色从 M0 起就成立。

### 1.1 官方 `dsh` runtime

Cordis 只负责插件的加载、卸载和依赖。Agent 的具体能力全部住在插件里：模型、工具、技能、会话、沙箱、存储、循环、调度、UI。开发者在配置层选择、替换或扩展任一能力，**不必改 DeepSeek Harness 源码**。

A running `dsh` is a plugin tree composed at boot from ordered layers. There is no privileged core to patch.

`dsh-base` 是每个 profile 的第一层：模型适配、工具、持久化、沙箱与审批策略、设置、凭据、遥测。官方 `web` profile 再叠 `dsh-web-app`；官方 `headless` 叠一个无服务器的一次性 runner。

**Studio 不叠 `@deepseek-ai/dsh-web-app`。** 不是因为它是「网页」，而是因为它是**另一个 surface 的组合**：它绑 TCP 端口、装 webserver、装浏览器 roster、按它自己的产品判断 disable 一批 agent 平面行。我们要的是同样这套零件的**不同组合**，不是它的成品。

### 1.2 Carrier — `dsh-carrier-macos`

`@deepseek-ai/dsh-host-apiproxy` 的包头注释是这套架构的地基，值得原样引用：

> the API gateway **every client shape shares** … **Transport-agnostic by design: this package registers no routes — physical carriers wrap `ctx.apiProxy` themselves.**

配套发布的 `AbstractApiClient`，其抽象方法 `doFetch` 的文档把可选传输列成：「browser fetch、injected handler.fetch、**IPC bridge**、…」。

所以一个原生客户端要接进来，官方留的位置就是 **carrier**：一个把 `ctx.apiProxy` 送出 Node 进程的物理管子。carrier 不定义业务语义，不发明方法名，不做鉴权以外的策略。

官方 web 载体本身就是这样一个 carrier（`dsh-client-connection` 把 `toFetchHandler` 挂到 `dsh-host-webserver` 上）。所以「用官方载体」和「写自己的 carrier」不是路线之争，是同一条路上的两站：**先用官方那根管子把客户端做对，最后换成自己那根省掉端口。** 详见 [§3](#3-carrier-contract)。

### 1.3 Host backends — 原生能力是后端，不是外壳

harness 里「原生 OS 能力」已经是成熟的 seam 家族，官方自带范本：

| seam | 抽象 | 官方后端 | Studio 的位置 |
| --- | --- | --- | --- |
| `ctx.directoryPicker` | `DirectoryPicker`，`capability()` 返回可辨识联合 | `-native`（macOS 上是 `osascript` 的 `choose folder`）/ `-browse`，由 `-auto` 采样选择 | **不用自己写**，保证 `-auto` 落到 native 分支即可 |
| `ctx.credentials` | `CredentialProvider`（`resolve` / `describe` / `set` / `unset`） | `dsh-credentials-local`：`$DSH_HOME/.credentials.yaml`，`0600` | 换成 Keychain 后端 |

`dsh-credentials` 的 README 明说这个 seam「为 keyring、辅助命令和 KMS 后端预留扩展」，并且钥匙串提供方「应作为平级包与本提供方并列」。

这条推论很重要，因为它否定了一个常见做法：**不要在 Swift 侧读 Keychain 然后把 API key 注入子进程环境变量**。那是把凭据泄进进程环境、绕开 `credentials/updated` 事件、并且让 `credentials.describe` 说谎。正确形态是一个实现 `CredentialProvider` 的插件行替换掉 `credentials-local`。

#### Keychain provider 怎么写

seam 的模型是：settings 和组合文件里存的是**引用**（POSIX shell 标识符形状，如 `DEEPSEEK_API_KEY`），provider 拥有值和存储。所以「引用长得像环境变量名」和「不要走环境变量传递」不矛盾——前者是命名，后者是传输。

四个具体决定：

**谁读钥匙串：一个随 app 分发、签过名的 helper，由插件 spawn。** 用官方的 `@deepseek-ai/dsh-native-command`——那是个零依赖的 no-shell `execFile` 库（不是插件、无 ctx、无状态），官方自己的两个消费者正是 `directory-picker-native` 的 OS 选择器和 `host.openPath`。我们做的事和它们同构。

**不要直接调 `security` 命令行。** Keychain 条目的 ACL 绑在调用方的代码签名上。授权给 `/usr/bin/security` 或给 `node`，等于授权给任何能跑它们的东西——那样钥匙串就只剩个存储功能，信任部分全丢了。签过名的 helper 才让「总是允许」这个选择是安全的。

**provider 内部要缓存。** seam 明确要求**消费者**每次操作都重新 `resolve()`（这样改了密钥不用重启就生效）。如果每次 LLM 请求都 spawn 一次 helper，既慢又会反复触发钥匙串交互。缓存归 provider 自己管，`set` / `unset` 后用 `notifyUpdated(ref)` 发 `credentials/updated` 失效。代价是用户在 Keychain Access.app 里手改不会被察觉——可接受，写进文档即可。

**shadowing 必须处理。** `set` 在只读来源遮蔽该引用时**必须拒绝**（否则写入看起来成功、解析却一直返回被遮蔽的旧值）。真实场景：用户 shell 里已经 export 了 `DEEPSEEK_API_KEY`，那 Studio 就写不进钥匙串。这是首次运行要讲人话的一个分支，不是一个可以吞掉的错误。

`describe()` 会返回 `source`（本地 provider 用 `env` / `file` / `project-env` / `user-env`，我们加一个 `keychain`），设置界面应该把它显示出来——「这个密钥来自哪里」正是用户在排查时最想知道的。

### 1.4 Client shape — `DSH.app`

Swift 侧要复刻的是 `AbstractApiClient` 注释里列全的那组协议不变量：rpcId minting、四象限信封 wrap/unwrap、schema 校验、下行解帧。这一层**不含产品逻辑**，它是协议实现。

下行解帧有两种，取决于载体：官方 web 载体是 **WebSocket**（M0–M3），我们自己的 carrier 是 **SSE**（M4）。这不是可以随便挑的——同一个 `/api/events.mux` 路径，前者 `GET` 直接返回 426 要求 upgrade，后者返回 `text/event-stream`。代价见 [§3](#swift-侧的真实代价)。

类型不手写。每个域都有 zod schema（`sessions.schema.js`、`events.schema.js`、`workspace.schema.js` …，且标注 browser-safe），用 codegen 生成 Swift `Codable` 并锁定 upstream 版本。harness 还是 developer preview，会破——codegen 让「上游改了字段」变成一次编译失败，而不是一次运行时静默错乱。

### 1.5 UI roster — 我们自己的浏览器插件行

见 [§4](#4-ui-策略路线-c)。一句话：官方 UI 是可逐行替换的 Cordis roster + SlotMap 树，我们组自己的 roster。

### 1.6 Profile `studio` 的真实叠层

A profile is a named composition stored in the Harness home. It lists the bundles it stacks, holds out-of-tree plugins, and keeps the user's own `cordis.patch.yml`.

```
empty root
  1. @deepseek-ai/dsh-base          # 官方第一层
  2. dsh-studio bundle              # carrier + host backends + client roster
  3. profile cordis.patch.yml       # 用户 / 产品覆盖
  4. home-level cordis.patch.yml
  5. --patch overlay
```

官方规则：一层 patch 按 **id** 瞄准一行，并**整份替换**该行的 `config`（没有 deep-merge）。用户可以在自己的 profile patch 里覆盖我们的 carrier 行（比如换 socket 路径），而不用改 bundle 源码。

检查机器上真正启动的树：

```sh
dsh --profile studio --dump-config
```

这条命令也是 M4 的验收工具：到那时输出里**不应该**再出现 `webserver` 行。在 M2–M3 期间它应该在——原因见 [§4](#client-plane-硬依赖-ctxwebserver)。

---

## 2. 已发布的扩展点（我们只用这些）

### 2.1 `ctx.apiProxy` 与 `toFetchHandler`

网关的 wire 契约是完整的、按域切分的、带 schema 的。`RpcMethodMap` 的 key 就是 wire 路径段（`POST /api/session.prompt`）：

```
session.*      list search create history models selectModel rename fork
               prompt attachment updateQueue cancel
subagent.*     list history prompt interrupt
host.*         describe pickDirectory listDirectory createDirectory openPath
workspace.*    list create rename delete insertBefore
               insertSessionBefore archiveSession
skill.list     agentPreset.*   goal.*   settings.*   credentials.*   llm.*
```

`toFetchHandler(api)` 是 published 导出，把 `ApiProxy` 变成一个纯 `fetch(Request) → Response`。它**自带流式**：`GET /api/events.mux` 和 `GET /api/events.host` 返回 `text/event-stream`，`data: {json}\n\n` 分帧，开流先发一行 `: connected` 注释。

浏览器那边用 WebSocket 是 `dsh-client-connection` 的选择，不是契约要求。原生客户端走 SSE 是**契约内**的路径，不是降级。

### 2.2 四象限信封

| 象限 | 形状 | 载体 |
| --- | --- | --- |
| `ClientRequest` | `{ type, rpcId, method, payload }` | `POST /api/<method>` |
| `ServerResponse` | `{ type, rpcId, result }` | 该 POST 的 body |
| `ServerRequest` | `{ type, rpcId, method, payload }` | SSE 帧 |
| `ClientResponse` | `{ type, rpcId, result }` | `POST /api/respond` |

两条必须记住的规则：**业务错误也是 HTTP 200** + `result.ok: false`（HTTP 状态只表达 carrier 层：404 未知路径 / 415 媒体类型 / 400 非 JSON / 500 handler 崩）；**响应永远回显请求的 `rpcId`，从不新发**。

### 2.3 `MuxFrame` / `HostFrame` — 其中两种帧必须应答

`MuxFrame` 是一个按 `type` 判别的 10 支联合（从 `muxFrameSchema` 实测得到，权威）：

```
session/event        session/subscribed    session/queue
session/jobs         session/projection    stream/error
approval/requested   approval/resolved
question/requested   question/resolved
```

对 Swift 很友好——每支的 `type` 都是 const，直接生成一个带 associated value 的 enum。三点提醒：

- **`stream/error` 不是正常结束。** 它是 impl 中途失败时发的最后一帧，客户端必须把它和「连接正常断开」区分开，否则用户看到的是「悄无声息地停了」。
- **`session/queue` 是待发队列的完整快照**，每次入队 / 改 / 删 / 领取后重发。产品上那份「可编辑可删的待发列表」就靠它。
- **`session/projection` 是侧栏数字和标题的来源**，和 `session/event` 是两条不同用途的流，别混着 fold。

其中**两种是可应答的 server-request**：

```ts
{ type: 'approval/requested', sessionId, approvalId, toolName, callId?, reason? }
{ type: 'question/requested', sessionId, questions }
```

不应答它们，agent 会**停在那里等**——`ctx.approval.request()` 在策略为 `ask` 且存在应答者时，Promise 就是不 resolve。这是原生客户端最容易漏、漏了最难查的一件事，属于 M1 而不是 M4。

应答走 `POST /api/respond`，原样回显那一帧的 `rpcId`。客户端能给的审批结果只有 `allowed-once` 和 `rejected`。

mux 流开流时会重放每个已附着会话的**未决**审批/提问帧，且 `rpcId` 逐字复用——这就是刷新恢复的基线。重连 = 重开流 + 重取 history，`since` 参数在 v1 未实现。

这条**实测验证过**：触发一次 bash 升权、拿到 `approval/requested` 后不应答直接断开下行、重开，重放帧的 `rpcId` 与断开前逐字一致，随后应答，那一轮正常跑到 `turn/end`。所以「用户在审批弹窗上把 app 关了」是可恢复的，不是一个卡死的会话。`dsh-probe approval` 就是这条断言。

升权的**触发链**也值得写下来，因为它决定审批卡片该显示什么：沙箱不会自己弹审批。agent 先照常调工具、被沙箱拒绝，然后**带着 `sandbox_permissions` 和一段自己写的 `justification` 重试同一次调用**，是那次重试产生了 `approval/asked`。也就是说用户被问的是「要不要把沙箱放宽到 `danger-full-access`」，不是「要不要跑这条命令」。产品侧的后果见 [docs/product.md](./docs/product.md)。

### 2.4 `session/event` 与投影

会话事件是写进仅追加日志的耐久事实。官方原则：**Model-visible means logged.** 能进模型请求的东西必须能从日志重建。

两条实现细节直接影响渲染正确性：

- 日志里有**打包分片行**（`text-chunks` / `reasoning-chunks` / `tool-call-chunks`，字段是 `seq0` / `time0` / `dt` / `texts`），不能假设一事件一行。
- `tool/call` / `tool/result` 帧可能附带 `view`（`ToolEventView`），那是 host 在发出事件时用 presenter 算出的**渲染意图，不持久化**。同一条事件在后一次投递可能带不同的 view 或不带。缺失时用客户端的文档化默认值（通用 JSON 卡片）。

聊天记录读事件流，侧栏的标题/统计/权限读**投影**（`session/projection` 帧 + history 尾页的 projections 块，higher-seq-wins）。`session_projcache.json` 是缓存不是权威。

不要在原生端另存一份「权威」聊天记录。

### 2.5 `ctx.agents`

`core/agent` 拥有 `Agent` 接口、活注册表和 `agent/*` 事件，挂在 `ctx.agents`。

官方对照表原文：

| Goal | Mechanism |
| --- | --- |
| Add UI or editor integration | drive `ctx.agents` and render from `session/event` |
| Add model-facing context | call `agent.inject()`; it lands in the next admitted request |

在我们的分层里，客户端**通过网关**间接驱动它（`session.prompt` / `session.cancel` / `session.fork`），而不是自己 inject `agents` 服务再直接调。理由很简单：网关已经把这些方法暴露成带 schema 的契约，而 `ctx.agents` 只在 Node 进程内可达。

`agent.inject()` 仍然是「把当前文件 / 选区交给 Agent」这类桌面功能的正确缝——它落在下一次被接纳的请求里，且不唤醒空闲的 agent。

但要说清楚：**它不在网关上。** `session.prompt` 的 `mode` 只有 `'queue' | 'steer'`，`RpcMethodMap` 里没有 inject 的对应项。所以这个功能对原生客户端不是免费的——需要加一个 host 插件把 `agent.inject()` 注册进已有的域再暴露出来（[§3 的约束](#约束)允许这条路，禁止的是在 carrier 上开私有路由）。在那之前只能用 `steer` 近似，代价是会唤醒一个本来空闲的 agent。

我们不重写 `ctx.agentLoop`。

### 2.6 Agent 平面必须走 presets

`dsh-web-app` 把 `tool-bash` / `tool-fs` / `tool-skill` / `tool-todo` / `tool-web` 等一整批行 `disabled: true`，改由 `dsh-agent-presets`（default `standard`）按会话 mount。它的 patch 里写明了原因：base 把工具挂在宿主全局，那是给单会话 TUI 的；多会话 surface 必须让每个会话挂自己的 preset。

**Studio 也是多会话 surface，必须照做。** 否则第二个会话就会在注册表上撞车。注意官方用 `disabled` 而不是删行，是防止 base 重排后静默复活——我们照抄这个做法。

### 2.7 Client 平面：`dsh.client` / SlotMap / renderer

浏览器里跑的是一棵 Cordis 树。要点：

- 一个包声明 `package.json` 的 `dsh.client`（`platform` / `inject` / `immediately`）并导出 `./client`，就是一个 client 插件。host 侧 `dsh-client-modules` 扫描已启用的行，把图注入 `window.__DSH_BOOT__`，按 `/plugins/<id>/client.js?rev=…` 供给。
- `ctx.slots.register({ name, children?, store?, inject?, ... }, Component)` 是唯一的组合 API。**声明即渲染授权**：一个 slot 必须先被父 entry 的 `children` 表声明，未声明就 `register` 会抛错。
- `SlotMap` 靠 TypeScript declaration merging 扩展，第三方声明自己的 slot 名。
- renderer 是可安装的 seam（`SlotRegistry.install`），官方实现是 `dsh-client-web-react.createSlotRenderer()`。**seam 可换，但官方 UI 组件本身是 React**，所以保留官方会话渲染 ≈ 保留 React 绑定层。

#### 写一个第三方 client 插件（已跑通）

一个包可以同时是 bundle 和 client 插件——`dsh-client-connection` 就是这么做的，我们的 `dsh-studio` 也是，这样不用再链接第二个包。

产物格式不是我们能选的：`dsh-client-modules` 服务 `/plugins/<id>/client.js`，shell 的模块表要求每个 bundle 自己调 `window.__ModuleLoader__.load({ id, factory })` 注册，`factory` 收到一个能解析共享运行时的 `require`。`packages/bundle/scripts/build-client.mjs` 用 esbuild 产 CJS 再套这层壳。

**哪些包留成 external 是关键**：`react` / `react/jsx-runtime` / 全部 `@deepseek-ai/*` 必须走注入的 `require`。自带一份 React 就是第二个模块实例——[同一个陷阱](#打包包只能存在一份)在浏览器侧的第三次现身，表现为 hooks 报错或组件对不上。

**两个 `inject` 意思完全不同，混了代价不小：**

| 位置 | 内容 | 例 |
| --- | --- | --- |
| `package.json` 的 `dsh.client.inject` | **包名**，shell 解析的加载边 | `@deepseek-ai/dsh-client-ui-layout` |
| 模块导出的 `inject` | **Cordis 服务名**，fiber 等待的对象 | `slots`、`layout`、`connection` |

在后者里填包名，插件会永远停在 PENDING。好在失败是响亮的——shell 直接拒绝启动并列出它在等哪些服务，所以这个错三十秒就能定位。

### 2.8 插件生命周期

`apply(ctx, config)` 是我们写入运行时的唯一入口。`inject` 列硬依赖服务名，Cordis 会把插件停在 PENDING 直到服务出现——**只 inject 真正会调用的服务**，占位式 inject 是噪音。`Config` 既是 TS 类型也是运行时 schema（`@deepseek-ai/schemastery`，或任何 Standard Schema 校验器），校验发生在 `apply` 之前。

socket、监听、定时器必须活在 `ctx.effect()` 里，这样 profile 热替换或卸载不会漏资源。顺序敏感的清理放进**一个** `ctx.effect` 的 disposer，在里面串行 await。

### 2.9 自组 surface bundle：实际要复刻什么

「不叠 `dsh-web-app`，自己组」这句话在 [§1.1](#11-官方-dsh-runtime) 说起来一行，落到 patch 上是几百行。写在这里，是因为低估这块工作量会直接打乱 M2 的排期。

`dsh-base` 之上、`dsh-web-app` 补齐的东西分三类，我们**每一类都要自己决定**：

**一、不 surface-specific，但 base 没装的 host 行（照抄即可）。**
`storage` / `storage-json` / `storage-domain`、`workspace`、`session-projection-cache`、`session-stats`、`message-feedback`、`session-log-export`、`api-gateway`（`dsh-host-apiproxy`）、`cordis-host-runner`、`code-runtime-worker-thread`、`plugin-inventory`、`directory-picker`（`-auto`）。没有它们，网关的一半域会 `service-unavailable`。

**二、浏览器交付层（M2–M3 期间照抄，M4 随客户端平面一起消失）。**
`webserver`、`frontend-static`（`distIndex` 指向 `@deepseek-ai/dsh-web-frontend/dist/index.html`）、`client-modules`、`connection`、`api-remotes`、`client-runtime`、`cordis-client-runner`、`locale`，加上我们自己挑的那批 `ui-*`。

**三、agent 平面的搬迁（必须自己做判断，不能照抄）。**
见 [§2.6](#26-agent-平面必须走-presets)。`dsh-web-app` 为此 `disabled: true` 了二十来行（`tool-bash` / `tool-pwsh` / `tool-fs` / `tool-fs-search` / `tool-str-replace-editor` / `tool-jobs` / `tool-skill` / `skill-filesystem` / `tool-goal` / `tool-todo` / `tool-web` / `tool-subagent*` / `tool-workflow` / `tool-ralph` / `plan-mode` / `compaction-basic` / `command-compact` / `tool-result-pruner` / `agent-instructions` …），再插入 `agent-presets`。

它的 patch 里对**每一行为什么留在 host 平面、每一行为什么进 preset**都写了理由（判据是「注入该服务的行属于 host 平面」「跨会话查询的注册表属于 host 平面」）。**照抄行、不照抄判据，是这一步最大的风险**：上游重排一次，我们就会在不知道为什么的情况下漏掉或多禁一行。

`dsh.bundle.patch` 只接受**一个**文件路径（实测：`dsh-app-boot` 读的是 `dsh?.bundle?.patch` 单值），所以三类只能在同一份 YAML 里分节，或者拆成三个 bundle 包各带一份 patch。当前用前者，节与节之间按「谁先消失」排序，M4 删掉的是中间那一节。

#### 自组 roster 的真实代价：依赖清单变成我们的了

这一条我原先写漏了，实测才暴露：`dsh-web-app` 不只是一份 patch，**它还是那 40 多个 `ui-*` 和 host 包的依赖清单维护者**。不叠它，就要在自己的 `package.json` 里逐个声明并跟着上游版本走。

这不是可以省的：patch 里写 `name: '@deepseek-ai/dsh-client-ui-conversation'`，loader 得能从 profile 里解析到它。本机之所以现在能跑，只是因为 `web` profile 早就把这些包拉进了 hoisted `node_modules`——**换一台干净机器就不成立**。

#### 打包：包只能存在一份

`dsh plugin --profile studio add <本地路径>` 用的是 pnpm 的 `link:` 协议，而 **pnpm 不会为 link 进来的包安装它自己的依赖**。所以那份清单需要另外补上——但**补的时候不能多补**。

包从两个地方解析：dsh 安装自带的共享 `$DSH_HOME/profiles/node_modules`，和 profile 自己的 `node_modules`。dsh 的报错原文就写着它「从 dsh installation **或** profile 目录」解析。

**把 dsh 已经自带的包再装进 profile，就会得到第二份模块实例。** 这不是浪费磁盘那么简单：好几个 harness 包用**模块局部的 `Symbol()`** 做内部查找。两份 `@deepseek-ai/dsh-tools` 意味着 `dsh-agent-loop` 拿着 A 副本的 symbol 去查 B 副本建的注册表，得到 `undefined`，然后**每一次工具调用**都死在：

```
Cannot read properties of undefined (reading 'prepare')
```

没有 module-not-found，没有任何指向打包问题的线索——错误出现在离病因最远的地方。这是实跑时真踩到的，不是假想。

所以规则是：**共享集是权威，只补真正缺的**。`tools/provision-profile` 按这条工作，并且在装完后主动检查有没有包同时存在于两处，有就报错退出。

一台干净机器上（dsh 安装带的包更少）会真的需要补装若干个，那时 profile 自己的 `node_modules` 里出现的是**共享集里没有的**包，不构成重复。

#### 为什么 glue 插件一个包都不 import

同一个陷阱的第三次现身，这次决定的是 glue 插件怎么写：**从 checkout 链接进来的 bundle 解析不到 profile 的依赖**（Node 走 realpath，从 checkout 往上找）。给它装一份自己的 `@deepseek-ai/cordis` 能修好解析，却会引入更糟的问题——Cordis 同样用模块局部的 symbol 标识服务，第二份拷贝意味着 `extends Service` 注册到了另一张符号表上，服务会静默地永远不出现。

所以 `packages/bundle/src/index.js` 只用鸭子类型的缝：`apply(ctx, config)` 加 `ctx.provide(name, value)`（后者会 notify 所有 inject 它的 fiber），除 Node 内置模块外零 import。代价是没有 `Config` 导出、没有 Schemastery 校验，只能手写校验——这是拿掉一个极难诊断的双内核 bug 换来的，值得。

#### 怎么把 bundle 装进 profile

`dsh plugin --profile studio add <spec>` 是published 命令，实测行为是三步：首次使用时初始化 profile、在 profile 目录里跑 `pnpm <args>`（参数原样转发，相对路径按调用目录锚定）、然后**按已安装包是否声明 `dsh.bundle` 自动对账 `dsh.profile.bundles`**。

也就是说我们的 bundle 只要 `package.json` 里有 `dsh.bundle.patch`，装进去就自动进层列表，不用手写那个数组。

一个连带的环境依赖：**它要求 `pnpm` 在 PATH 上**（找不到会直接报 `pnpm not found on PATH — install pnpm to manage profile plugins`）。所以首次运行的环境检查要查三样：Node、`dsh`、`pnpm`——不是两样。

---

## 3. Carrier contract

carrier 是一根管子，不是一个 API。它的全部职责：

```ts
export const name = 'dsh-carrier-macos'
export const inject = ['apiProxy']

export function apply(ctx: Context, config: Config) {
  const handler = toFetchHandler(ctx.apiProxy)
  ctx.effect(() => {
    const server = http.createServer((req, res) => bridgeNodeToFetch(req, res, handler))
    server.listen(config.socketPath)
    return () => { server.close(); rmSync(config.socketPath, { force: true }) }
  })
}
```

### 为什么是 Unix domain socket

不是洁癖，是三个具体问题：

**鉴权。** 官方明说 web carrier 的 `trustedHosts` 是**可达性策略而不是认证**，「Web 载体不提供认证层」。TCP loopback 上任何本机进程都能连上你的 agent 运行时。UDS 的 `0600` 文件权限就是鉴权，而且是操作系统给的。socket 放在应用自己的 Application Support 目录下。

**没有端口发现问题。** socket 路径是约定的常量。

这个问题在 M0–M3 期间仍然存在（那时还有 webserver），但**解法不是 `studio-desktop` 那种从 `dsh` 的 stdout 正则抓 `http://127.0.0.1:\d+`、再在 `127.0.0.1` 与 `localhost` 之间来回试**。`webserver` 那一行的 `host` / `port` 就在我们自己的 patch 里，直接钉死一个端口即可；抓 stdout 是把自己能决定的事变成了猜。

**特权方法。** `PRIVILEGED_METHODS`（`host.pickDirectory`、`host.openPath`、整块 settings / credentials、`llm.discoverModels` 等）在官方 web 载体里被要求空信任表，即仅回环。

这里有一条**必须说反过来的话**：那道 fence 住在 `dsh-client-connection` 里，**不在 `toFetchHandler` 里**（`api-proxy.js` 只有一句注释指向它）。carrier 直接包 handler 就意味着**根本没有 fence**。所以不是「UDS 顺带满足了特权方法的要求」，而是——

> **UDS 的文件权限是唯一的 fence。socket 的目录和 mode 弄错，等于把整个 agent 运行时（含 credentials 域）对本机所有进程敞开。**

这条要写进 carrier 的测试，不是写进注释。

### 精确的边界

- `toFetchHandler` 是 published 导出（`@deepseek-ai/dsh-host-apiproxy` 根导出）。
- `dsh-client-connection` 内部那个 node:http ↔ fetch 的 `bridge()` **不在它的 `exports` 里**，不能 import。那 40 行胶水要自己写：读完 body → 造 `Request` → 调 handler → 回写 status/headers → **SSE body 逐块 pipe 且不缓冲** → 客户端断开时 abort。
- 这是整个方案里唯一自写的协议代码，它不碰任何业务语义。

### Swift 侧的真实代价

「换一根管子」这个说法对 Node 侧成立，对 Swift 侧不成立。两件事同时变：

| | 官方 web carrier（M0–M3） | UDS carrier（M4） |
| --- | --- | --- |
| HTTP 栈 | `URLSession` 直接可用 | **`URLSession` 不支持 UDS**，要 SwiftNIO 或 `NWConnection` + 手写 HTTP/1.1 |
| 下行 | WebSocket（`GET /api/events.mux` 直接返回 426 要求 upgrade） | SSE（`toFetchHandler` 对同一路径返回 `text/event-stream`） |

所以从官方载体切到 carrier，Swift 侧换的是 HTTP 客户端实现**和**下行协议解析。把这次切换排在 M4、且排在 WebView 消失之后，是为了让它成为**一次性**的、不必和产品功能并行的改动。

如果早期就想避免这次重写，选项是从 M0 起直接用 SwiftNIO 抽象传输——代价是给一个 SwiftUI app 引入 NIO 依赖，而 M0 的目的本来是「用最少的东西证明协议」。这份文档选后者，把重写成本明确留在 M4。

### 何时做（不是第一个里程碑）

carrier 是**终点形态，不是起点**。原因在 [§4](#client-plane-硬依赖-ctxwebserver)：只要还有一行官方 client 插件在渲染，组合里就必须有一个 loopback TCP webserver，UDS 省不掉那个端口，安全收益被抵消。等 [§4 的原生化顺序](#路线-c先组-roster-换-chrome再逐-slot-原生化)走完、客户端平面清空，carrier 才既省端口又省一层。

### 约束

- carrier 只绑 UDS，永远不绑 TCP，更不绑 `0.0.0.0`。（M2–M3 期间组合里还有一个 `webserver` 行，那是浏览器平面的，和 carrier 无关；它按官方默认绑 `127.0.0.1`。）
- 生命周期 = 插件生命周期。`ctx.effect` 打开，卸载时关掉并删 socket 文件。
- **不新增方法名。** 需要一个网关没有的能力时，正确做法是加一个 host 插件把它注册进已有的域，或者走 Typert Remote（`namespace/method`，由 gateway intercept），而不是在 carrier 上开一条私有路由。
- carrier 可换。日后 Windows / Linux 宿主换一根管子（named pipe / abstract socket），Swift 与 Tauri 两端共用同一份 wire 契约。

---

## 4. UI 策略：路线 C

### 「iframe 官方 Web UI」和「组自己的 roster」是两件事

这是本文档纠正的最重要的一个混淆。

**iframe** = 把 `dsh --profile web` 跑起来，用 WebView 加载它的 `:3080`，得到一个完整的、别人组好的产品，你只能在外面加边框。

**roster** = 你自己在 profile 里列浏览器插件行。`dsh-web-app` 不参与。你选哪些 `ui-*` 行进来、哪些不要、哪些换成自己的。这和在 host 平面替换 `credentials-local` 是同一件事，只是发生在浏览器那一侧。

后者才是「一切皆插件」的字面意思。前者是套壳。

### 路线 C：先组 roster 换 chrome，再逐 slot 原生化

我们保留官方的会话渲染行（`ui-conversation` 及其下游：`ui-tool` / `ui-deliverables` / `ui-plan` / `ui-user-questions` / `ui-skill` / `ui-subagent` / `ui-goal` / `ui-model-selection` …），换掉 chrome 行，SwiftUI 拿走窗口、菜单、命令面板、通知、设置、工作区。

然后按产品价值排序，一个 slot 一个 slot 换成原生。**替换单位是「一行」，不是「一层」**——这正是 harness 自己的粒度。每换一个 slot 都是可发布、可回退的增量，而不是一次「原生重写」豪赌。

原生化顺序（按收益/成本比）：

1. **composer 及其 chain** — 输入法、快捷键、拖放、粘贴图片，是原生优势最大、web 体验最差的地方。**审批面板和用户提问也占在这条 chain 上**（`conversation.composer`），而 [产品标准](./docs/product.md) 把审批列为主线交互、要求纯键盘可完成——所以这一步同时兑现两条，排第一不是因为它容易。
2. **运行态与产出物** — `conversation.session.header` 一带加 turn tail。数据来自 `sessionStats` 投影和 host 流的运行态翻转。产品标准里「等待是一个要设计的界面」落在这里。
3. **侧栏 / 会话列表 / 命令面板** — 本来就该在原生侧，数据来自 `workspace.*` 和投影。
4. **设置与插件管理** — 数据来自 `settings.describe` 和 `pluginInventory/list`。
5. **会话流本身** — 最后，或者永远不换。它的成本见下。

### 为什么会话流放最后

两个理由，第二个更硬。

**一、presenter 词汇表。** `ToolEventView` 是 host 侧 presenter 算出来的渲染意图，每个工具一套词汇（`tool.call.toolview` 是 keyed slot），不持久化，且上游还在 preview 期演进。自己画等于长期跟着别人的词汇表跑。

**二、事件 payload 的类型不在 codegen 覆盖范围内。** 见 [§6](#6-跟住一个没有版本号的上游)：`SessionEvent.data` 在 zod 里是 `unknown`，真类型由 22 个包 declaration-merge 进 `SessionEventMap`。留在官方渲染行里，这些类型由 TypeScript 编译器替你盯着；搬到 Swift，就变成手写且无人盯的一摊。

先借官方的，等词汇表稳定、或等某个具体工具视图的原生收益足够明确，再逐个换。

### Client plane 硬依赖 `ctx.webServer`

这是路线 C 最重要的一条工程约束，也是 roadmap 把 carrier 排到最后的直接原因。

浏览器那棵树不是凭空跑起来的，它的三个交付环节全部挂在 `ctx.webServer` 上：

- `dsh-client-modules` 用 `ctx.webServer.tapIndex()` 把 `window.__DSH_BOOT__` 注进 index.html，用 `ctx.webServer.register({ path: '/plugins' })` 供给每个插件的 `client.js`。
- `dsh-host-frontend-static` 占的是 webserver 的 fallback seat，负责 SPA dist（`@deepseek-ai/dsh-web-frontend` 的 `./dist/*` 是published 导出，`distIndex` 由组合方给）。
- `dsh-client-connection` 在 webserver 上注册 `/api` 前缀和两条 WebSocket upgrade。

而 `dsh-host-webserver` 的 `host` 类型就是 `'127.0.0.1' | '0.0.0.0'`——**只能 TCP**。

结论：**只要还有一行官方 `ui-*` 在渲染，组合里就必须有一个 loopback webserver。** 这不是妥协，这是路线 C 的成本；它在 M2–M3 期间一直在，随最后一个 slot 被原生化而消失。

有一条理论上的绕法是让 WKWebView 用 `WKURLSchemeHandler` 自服务前端资产、并把 `/api` 代理到 UDS。它需要 Swift 侧拿到 boot graph 和插件 bundle 字节，而这两样都不在 `RpcMethodMap` 里——要么新增 surface（违反 [§3 的约束](#约束)），要么重实现 `client-modules` 的宿主半边。**不采纳**，代价高于它省下的那个端口。

### 换 layout 的硬约束

不能只 `disabled: true` 掉 `ui-layout` 了事。`ui-conversation` 的 `dsh.client.inject` 里有 layout，`apply` 里直接读 `ctx.layout`；shell 的 `app-shell` 也 inject `layout`。裸删会让两者都停在 PENDING。

我们的 layout 插件必须做到三件事：

1. 占住 `root`，并在 `children` 里**声明** `conversation`（以及仍要用的 `details` / `shell.overlay`）——未声明，`ui-conversation` 的 `register` 会抛错。
2. `provide` 一个满足 `ILayout` 的 `ctx.layout`（`toggleSidebar` / `openDetails` / `closeDetails`）。
3. 继续挂 theme presenter，把 `ctx.theme` 快照投到 DOM，否则 `--dsw-*` token 不落地。

同理，如果只换 `ui-sidebar`，要自行声明它原本声明的 `sidebar.workspaces` / `sidebar.settings` 等子座位，否则 `ui-workspace` / `ui-settings` 的注册会挂。

耦合的准确描述是：**松在 slot 边界，紧在服务名与声明契约**。

---

## 5. Roadmap

排序原则：**每个里程碑结束时都必须有一个能用的产品**，不允许出现「旧的拆了、新的还没有」的空窗。这条原则决定了 carrier 排在最后而不是中间，理由见 [§3 何时做](#何时做不是第一个里程碑)。

| 里程碑 | 内容 | 验收标准 |
| --- | --- | --- |
| **M0** | Swift `ApiClient`：四象限信封 + rpcId + WebSocket 下行 + `tools/schema-codegen`。**打现有 `dsh --profile web` 的 `:3080`**，零 Node 代码 | 一个 Swift 命令行测试跑通 `session.create` → `session.prompt` → 从 mux 流读到 `assistant/chunk` |
| **M1** | 审批与提问闭环；进程监督（发现 / 拉起 / 健康检查 / 优雅退出 `dsh`） | 触发一次 bash 升权，原生弹窗，`respond` 后 agent 继续；杀掉 UI 重开不留悬挂 approval；PATH 里没有 `dsh` 时给的是动作不是栈 |
| **M2** | `studio` bundle：自组 client roster（含复刻必需的 host 行 + 切 presets，见 [§2.9](#29-自组-surface-bundle实际要复刻什么)）+ 自写 layout 插件 + SwiftUI chrome。**保留 loopback webserver** | 不叠 `dsh-web-app` 也能起完整会话；`--dump-config` 里是我们自己的 roster；首次运行五步不出现 Cordis 术语 |
| **M3** | 逐 slot 原生化，从 composer chain 开始（顺序见 [§4](#路线-c先组-roster-换-chrome再逐-slot-原生化)） | 每个 slot 独立可回退；关掉原生实现能落回官方行 |
| **M4** | 客户端平面清空后：`dsh-carrier-macos`（UDS）+ Keychain `CredentialProvider`；Swift 侧一次性换 HTTP 栈 | `--dump-config` 里没有 `webserver` 行；`lsof` 看不到 TCP 监听；app 仍完整工作 |

M0 故意先蹭现成的 web carrier：它让 Swift 客户端的正确性在**没有任何自研 Node 代码**的前提下被证明。协议调不通时，你能确定问题在 Swift 侧。

M1 的进程发现有个具体结论值得先记下：**不要假设 `dsh` 在 PATH 上。** 一台正常用着 harness 的机器上很可能压根没有全局安装（`npx @deepseek-ai/dsh web` 就够用了）。三个候选里，优先级应该是：

1. **从 profile 自己的 `node_modules` 解析** `@deepseek-ai/dsh/lib/bin.js`——版本和 profile 精确对齐，启动不走网络。
2. PATH 上的 `dsh`（用户自己全局装了）。
3. `npx --yes @deepseek-ai/dsh` 兜底——慢，且版本不受我们控制。

`studio-desktop` 的顺序是 2 → 3，漏了 1，于是在没全局装的机器上每次冷启都要过一遍 npx。

但第 1 条要带个警告，这是实测发现的：在一台 npx 装出来的机器上，`profiles/node_modules/@deepseek-ai/dsh` 是一条**指向 npx 缓存的符号链接**（`~/.npm/_npx/<hash>/…`），而且同一台机器上正在跑的那个实例来自**另一个** npx hash。也就是说这个路径存在、可用、版本对齐，但它的落点是一个 `npm cache clean` 就会消失的目录。

所以解析器要**验证链接目标真的可执行**，失败就往下一条走，而不是把「文件存在」当成「能跑」。

Keychain `CredentialProvider` 排在 M4 是因为它和 carrier 同属「host 后端」这批工作，一起做省一次 profile 变更。如果首次运行的密钥体验先卡住了产品，可以提前单独做——它不依赖 carrier，只是不值得为它单独动一次组合。

---

## 6. 跟住一个没有版本号的上游

网关协议目前没有版本字段，官方把协商列为「独立客户端出现后再说」的延期项。

实测比这更糟一层：**wire 上根本读不到契约版本。** `host.describe()` 确实返回一个 `version`，但按它自己的文档，那是 *host app（`apps/cli`）的 package.json 版本*——本机跑出来是 `0.0.1`，而契约包 `@deepseek-ai/dsh-host-apiproxy` 是 `0.1.0-rc.6`。两者不是一回事，也不同步。

所以**「启动时比对版本号」这条路是不存在的**，契约漂移只能靠结构化手段发现。三道防线：

**一、codegen 而不是手写类型。** 走 zod → JSON Schema → Swift `Codable`，产物进 `app/Sources/DSH/Generated/`，不手改。上游改字段 = 一次编译失败。

这条已经用 `0.1.0-rc.6` 实测过，不是推断。结论如下：

| 事实 | 结果 |
| --- | --- |
| zod 版本 | `4.4.3`，自带 `z.toJSONSchema()` |
| 导入路径 | `./api` 与 `./api/*` 都是published 导出（`@deepseek-ai/dsh-host-apiproxy/api/sessions.schema`） |
| 16 个域全部 schema | **151 个可直接转换，7 个失败** |
| 7 个失败里的 6 个 | `z.custom()`（`muxFrame` / `hostFrame` / `rpc.*`），加 `{ unrepresentable: 'any' }` 即可转 |
| 第 7 个 | `downloads.sessionLogQuerySchema` 是 transform，那是 query 解析，客户端不需要 |

两个 codegen 必须自己处理的坑：

**brand 会丢。** `sessionIdSchema` 转出来就是 `{"type":"string","minLength":1}`，Swift 侧拿到裸 `String`。好在 brand schema 的导出命名是规整的（`sessionIdSchema` / `messageIdSchema` / `workspaceIdSchema` / `attachmentIdSchema`），按名字后处理生成 Swift newtype 可行。

**方法→schema 的映射表没有导出。** `fetch/client.js` 里那张 `UNARY_VALUE_SCHEMAS` 是模块私有的（`./client` 只导出 `AbstractApiClient` 和 `InProcessApiClient`）。codegen 只能靠命名约定推导：`session.list` → `sessionListRequestSchema` + `sessionListValueSchema`。约定目前 100% 成立，但**约定不是契约**——所以 codegen 必须带一条断言：从 `rpc-map.d.ts` 抽出全部方法 key，每个都要能找到两个 schema，找不到就 fail。这条断言比生成出来的类型更重要。

**codegen 覆盖不到什么，必须写明白：** `sessionEventSchema` 的 `data` 是 `z.unknown()`——刻意的，因为事件类型是 merge-extensible。真正的每类事件 payload 住在 `SessionEventMap` 里，而那个接口由 **22 个包**通过 TypeScript declaration merging 各自扩展。

所以 codegen 给你的是**信封和 RPC 层**，不是会话事件的内容。这一层想要类型安全，只有两条路：从 `.d.ts` 上再做一套 codegen（要跨包解析 declaration merging，明显更难），或者手写并接受它会漂。

这条限制不是小事——**它是「会话流原生化排最后」的第三个理由**，比 `ToolEventView` 那条更硬：路线 C 保留官方渲染行，等于把这 22 个包的类型维护成本留在 TypeScript 那一侧，那里编译器是替你干活的。

**二、录制的 mux 流当 fixture。** `tools/record-fixtures` 录一段真实下行流（当前 915 帧，含完整审批往返和流式分片行）存进 `app/Tests/Fixtures/`，喂回**真正的解码路径**（`MuxStream.decode`，不是测试里另写一份）。

核心断言不是「能解码」，而是**没有任何一帧落进 `.unknown`**。`.unknown` 是刻意留的容错分支——上游加一种帧或一个枚举值时客户端不该崩——但正因为不崩，漂移就没人发现。这条断言把静默的容错变成响亮的失败。

fixture 自身也要被守住：另有一条测试要求录制里必须出现 `approval/requested` 等五种帧，否则一份从「你好」会话录来的语料会让所有测试空转着通过。

**三、对着真 `dsh` 的冒烟。** 这就是 `dsh-probe` 的职责：`host.describe` → `session.create` → `session.prompt` → 从 mux 流读到 `assistant/chunk`。它抓的是 codegen 和 fixture 都抓不到的那类破坏——组合层的行变了、服务名换了、某个 host 行不再存在。**在没有版本号可比的世界里，这个探针就是版本检查。**

每个实现 PR 都要写明测过的官方 `dsh` 版本（`node -p "require('$DSH_HOME/profiles/node_modules/@deepseek-ai/dsh-host-apiproxy/package.json').version"`）。

---

## 7. What we will not do

- No fork of `deepseek-ai/deepseek-harness`. Runtime stays official `dsh`.
- No upstream PR as a product gate. 官方已经把 UI 和 transport 都留成了插件层。
- **No bespoke RPC surface.** 不发明方法名，不开私有路由。契约是 `RpcMethodMap`。
- **No iframe of `dsh --profile web`.** 我们组自己的 roster；`dsh-web-app` 不进 `studio`。（M0 打 `:3080` 是协议测试台，不是产品形态——那时还没有 `studio` bundle。）
- No Electron start. Mac 是 SwiftUI；日后 Win/Linux 换一根 carrier 管子。
- No credentials in process env. Keychain 走 `CredentialProvider`，不走环境变量注入。
- No polling where a stream exists. mux/host 流是 push 的。
- No unpublished APIs. 跟着已发布的缝走，预期 preview 会破。
- No App Sandbox in v1. See [docs/product.md](./docs/product.md).

---

## 8. Repository layout

```
app/
  Sources/DSHKit/           # 协议层：官方 ApiProxy 契约的 Swift 面，无产品逻辑
    Generated/              #   由 zod schema 生成，不手改
  Sources/DSHHost/          # 本机运行时生命周期：找到 / 拉起 / 停掉 dsh
  Sources/dsh-probe/        # 验收探针 / 冒烟（§6 第三道防线）
  Sources/DSH/              # SwiftUI 宿主 — M2 起
  Tests/Fixtures/           # 录制的 mux 流（§6 第二道防线）
packages/bundle/            # studio bundle
  patch/host.yml            #   §2.9 第一类：必需的 host 行
  patch/browser.yml         #   §2.9 第二类：浏览器交付层 — M4 整份删掉
  patch/agent-plane.yml     #   §2.9 第三类：disable + presets，逐行带理由
packages/client-layout/     # 我们的 layout 插件（占 root，声明 conversation）
packages/carrier-macos/     # UDS carrier — M4
packages/host-keychain/     # CredentialProvider 后端 — M4
tools/schema-codegen/       # zod → JSON Schema → Swift Codable
docs/                       # product notes
```

三层分开是有意的。`DSHKit` 不依赖 SwiftUI，也不管进程——它只是契约的 Swift 面，能被探针、测试、日后的 CLI 各自消费。`DSHHost` 管本机进程生命周期，那**不属于契约的任何一部分**，所以不该混进 `DSHKit`。M4 换 carrier 时，改动范围是 `DSHKit` 里的传输那两个文件。

浏览器交付层单独一个 patch 文件，是为了让 M4「客户端平面清空」变成删一个文件，而不是在一大坨 YAML 里做外科手术。

---

## 9. 修订记录

这份文档的上一版基于三个前提，它们在读过运行时的已发布类型面之后不成立。记在这里，是因为 `studio-desktop` 分支是按旧前提实现的，读代码的人需要知道差异从哪来。

| 旧前提 | 实际 |
| --- | --- |
| 「桥是 Studio 的产品表面，不是 DeepSeek 的公共 API」 | `ctx.apiProxy` 就是官方为「每一种 client shape」发布的网关，且明确要求由 carrier 包。自造路由等于放弃 50 个带 schema 的方法。 |
| 「不 iframe 官方 Web UI」= 必须纯原生渲染 | 假二选一。官方 UI 是浏览器里的 Cordis roster + SlotMap 树，逐行可替换。组 roster 不是 iframe。 |
| 「原生宿主」是包在 `dsh` 外的一层 | 原生能力在 harness 里是 Service seam 的后端（`DirectoryPicker` / `CredentialProvider` 已有范本）。宿主同时是 client shape 和几个 host 后端。 |

`studio-desktop` 分支里值得保留的是进程监督骨架（PATH 补全、npx 回退、Node 版本检查、SIGTERM→SIGKILL 阶梯）、Keychain 封装、工作区书签、首次运行与空状态骨架、主题 token 契约。该废弃的是那座自研 HTTP 桥（`/health` `/status` `/theme` `/notify-test` 五条私有路由 + 2 秒轮询出通知）、占位式的 `inject: ["agents"]`、以及只写剪贴板的 composer。

### 9.1 本文档自身的修正

第一版把 carrier 排在 M2，并写「验收标准：`--dump-config` 里没有 `webserver` 行」。**那是错的**，而且是排期级别的错：路线 C 保留官方 `ui-*` 行，而 client plane 硬依赖 `ctx.webServer`（[§4](#client-plane-硬依赖-ctxwebserver)），所以那条验收标准和它后一个里程碑互斥；照原顺序执行，M2 结束时会得到一个拆掉了 web-app、又还没有替代 chrome 的空窗版本。

同时修掉的还有三处：

- 原文说「UDS 天然满足 `PRIVILEGED_METHODS`」。fence 在 `dsh-client-connection` 里，不在 `toFetchHandler` 里；carrier 直接包 handler 是**没有** fence，UDS 权限是唯一那道。方向说反了。
- 原文把 Swift 侧切换载体说成「换一根管子」。实际同时换 HTTP 栈（`URLSession` 不支持 UDS）和下行协议（WebSocket → SSE）。
- 原文只写「agent 平面必须走 presets」，没给自组 bundle 的实际工作量（[§2.9](#29-自组-surface-bundle实际要复刻什么)）。
