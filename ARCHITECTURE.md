# Architecture

DSH Studio 是官方 DeepSeek Harness 上面的一层 **bundle + profile + 原生宿主**。
它不实现 Agent 循环，不 vendor `dsh`，不 fork [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

This document only uses extension points published by DeepSeek Harness. If an API is not in the official docs, it is not an extension point we depend on.

官方参考：

- [DeepSeek Harness Architecture](https://deepseek-harness.github.io/deepseek-harness/en/reference/)
- [Cordis Primer](https://deepseek-harness.github.io/deepseek-harness/en/reference/cordis-primer)
- [Plugins and lifecycle](https://deepseek-harness.github.io/deepseek-harness/en/develop/framework/)
- 产品页：[deepseek.com/harness](https://deepseek.com/harness)

---

## 1. Layers

```
┌─────────────────────────────────────────────────────────────┐
│  Native shell                                               │
│  macOS: SwiftUI (first)                                     │
│  Windows / Linux: later Tauri host, same bridge contract    │
│  windowing · keychain · notifications · file dialogs        │
└──────────────────────────▲──────────────────────────────────┘
                           │  loopback only (127.0.0.1)
                           │  never bind 0.0.0.0
┌──────────────────────────┴──────────────────────────────────┐
│  dsh-studio bundle  (TypeScript Cordis plugin)              │
│  apply(ctx) · inject · Config / Schemastery · ctx.effect    │
│  drive ctx.agents · render from session/event               │
│  package.json → dsh.bundle.patch → cordis.patch.yml         │
└──────────────────────────▲──────────────────────────────────┘
                           │  official plugin tree
┌──────────────────────────┴──────────────────────────────────┐
│  Official dsh runtime                                       │
│  Cordis kernel + @deepseek-ai/dsh-base + user patches       │
│  sessions · tools · llm · agent loop · sandbox · storage    │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 Official `dsh` runtime

Cordis 只负责插件的加载、卸载和依赖。Agent 的具体能力全部住在插件里：模型、工具、技能、会话、沙箱、存储、循环、调度、UI。开发者在配置层选择、替换或扩展任一能力，**不必改 DeepSeek Harness 源码**。

A running `dsh` is a plugin tree composed at boot from ordered layers. There is no privileged core to patch.

`dsh-base` 是每个 profile 的第一层：模型适配、工具、持久化、沙箱与审批策略、设置、凭据、遥测。官方 `web` profile 再叠 `dsh-web-app`；官方 `headless` 叠一个无服务器的一次性 runner。

**DSH Studio 不叠 `dsh-web-app` 当产品 UI。** 我们叠自己的 bundle。官方网页可以继续作为对照或调试入口，但不是 Studio 的表面。

### 1.2 `dsh-studio` bundle

一个 bundle 是 Cordis 配置行 + 它所挂载代码的分发格式。`package.json` 里的 `dsh.bundle` 指向 patch 文件（通常是 `cordis.patch.yml`）。profile 作曲器通过这个字段解析 patch，而不是通过一段「特殊启动代码」。

我们的 bundle：

- 导出 `apply(ctx, config)`，以及可选的 `name`、`inject`、`Config`
- 用 `dsh.bundle.patch` 把自己插进 `studio` profile
- 在 `127.0.0.1` 上开一座 **bridge**（仅 loopback），把原生宿主接到官方运行时
- 按官方指引：**驱动 `ctx.agents`，从 `session/event` 渲染**
- 用 `ctx.effect()` 注册桥和监听，卸载时自动收回

它不实现 agent loop，不注册自己的模型适配器来「取代」官方循环，也不把官方 Web Client 再包一层。

### 1.3 Native shell

Mac 优先的 SwiftUI 应用拥有窗口、菜单、钥匙串、通知、文件对话框、工作区切换。它是 bridge 的客户端，不是 `dsh` 的 fork。

Windows / Linux 稍后用 Tauri 宿主消费 **同一份 bundle / 同一份 bridge 契约**。跨平台发生在桥的这一侧，而不是再做一套 Electron 网页。

### 1.4 Profile `studio`

A profile is a named composition stored in the Harness home. It lists the bundles it stacks, holds out-of-tree plugins, and keeps the user's own `cordis.patch.yml`.

`studio` 的意图叠层：

```
empty root
  1. @deepseek-ai/dsh-base          # official first layer
  2. dsh-studio bundle              # our surface + 127.0.0.1 bridge
  3. profile cordis.patch.yml       # user / product overrides
  4. home-level cordis.patch.yml
  5. --patch overlay
```

官方规则：一层 patch 按 **id** 瞄准一行，并 **整份替换** 该行的 `config`（没有 deep-merge）。用户可以在自己的 profile patch 里覆盖我们的 bridge 行，而不用改 bundle 源码。

检查机器上真正启动的树：

```sh
dsh --profile studio --dump-config
```

打印出来的任何一行，都可以被再上一层 patch 换掉。

---

## 2. Extension points (published only)

只依赖官方已经写进文档的缝。下面是 Studio 会用到的，以及明确不会发明的。

### 2.1 `apply(ctx)`

插件是实现了 Service 的对象：带可选 `inject` / `apply(ctx)` 的函数，或由 Cordis 挂进当前 context 的 `Service` 子类。

`apply` 是我们写入运行时的唯一入口。在这里注册监听、打开 bridge、把 disposers 交给 context。

### 2.2 `inject`

`inject` 列出硬依赖的服务名。Cordis 会把插件停在 PENDING，直到这些服务存在；某个服务被卸掉时，依赖它的插件也会卸掉，服务回来再装上。加载顺序由服务依赖表达，而不是靠文件顺序。

Studio bundle 只 `inject` 官方已发布、且做桌面 UI 真正需要的服务。官方把「加 UI / 编辑器集成」指向 `ctx.agents`，所以 `agents` 是硬依赖。其它能力用 `ctx.get(...)` 探测，缺了也能活。

### 2.3 `Config` / Schemastery

每个 Cordis 行可以带 `config`。插件导出的 `Config` 既是 TypeScript 类型，也是运行时 schema。官方教程用 `@deepseek-ai/schemastery`；Cordis 接受任何 Standard Schema 校验器。普通对象当 `Config` 导出是不够的。

校验在 `apply` 之前发生。坏配置让插件加载失败，而不是半配置跑起来。Studio 的可调项（桥端口、是否在 turn 结束时通知、工作区默认值）都走这套 schema，并带上默认值。

### 2.4 `ctx.effect`

注册是可逆的 effect。`ctx.on(...)`、工具 / 适配器注册、以及 `ctx.effect(() => disposer)` 都会在插件卸载时收回。桥的 socket、文件监视、定时器必须活在 `ctx.effect` 里，这样 profile 热替换或卸载不会漏端口。

顺序敏感的清理放进 **一个** `ctx.effect` 的 disposer，在里面串行 await。

### 2.5 `session/event`

会话事件是写进仅追加日志的耐久事实，并通过 `session/event` 广播。官方原则：**Model-visible means logged.** 能进模型请求的东西必须能从日志重建。

Studio 的会话表面从这条流渲染（恢复、分叉、检索、回放都走同一份事件流）。需要在重载后还在的事实，用 session 事件；不要在原生端另做一份「权威」聊天记录。

### 2.6 `ctx.agents`

`core/agent` 拥有 `Agent` 接口、活注册表和 `agent/*` 事件，挂在 `ctx.agents`。

官方对照表原文：

| Goal | Mechanism |
| --- | --- |
| Add UI or editor integration | drive `ctx.agents` and render from `session/event` |
| Add model-facing context | call `agent.inject()`; it lands in the next admitted request |

原生宿主通过 bridge 调用 `ctx.agents`（创建 / 恢复 / 注入 / 取消），UI 订阅 `session/event`（以及需要观察飞行中工作的 `agent/*`）。我们不重写 `ctx.agentLoop`。

`agent.inject()` 是官方提供的「把上下文送进下一次被接纳的请求」的方法。桌面侧的「把当前文件 / 选区交给 Agent」走这条缝，而不是改 system prompt 插件。

---

## 3. Bridge contract (our surface, not an upstream API)

桥是 **Studio 的产品表面**，不是 DeepSeek 的公共 API。它存在的唯一理由：让原生进程和 Cordis 进程解耦，同时把官方扩展点留在 `dsh` 进程内。

约束：

- 只绑 `127.0.0.1`。不监听局域网。
- 生命周期 = 插件生命周期。`apply` 里用 `ctx.effect` 打开，卸载时关掉。
- 语义对齐官方：会话状态以 `session/event` 日志为准；活的控制面对齐 `ctx.agents`。
- 原生壳和日后的 Tauri 宿主共用同一份契约。桥稳定，两端壳可以换。

第一版路由（仅 loopback JSON）：GET /health、GET /status、GET /theme、POST /theme、POST /notify-test。默认 `127.0.0.1:43180`。theme 热更新会返回 tokens 与 `--dsh-*` CSS 变量，供 WKWebView 注入。

---

## 4. What we will not do

- No fork of `deepseek-ai/deepseek-harness`. Runtime stays official `dsh`.
- No upstream PR as a product gate. Official docs already treat UI as a plugin.
- No Electron start. Mac is SwiftUI; later Win/Linux reuse the same bridge via Tauri.
- No official Web UI iframe. That product already exists three times.
- No unpublished APIs. Follow the documented seams; expect preview breakage.
- No App Sandbox in v1. See [docs/product.md](./docs/product.md).

---

## 5. Repository layout

```
app/                         SwiftUI macOS 14+ host (Package.swift + DSH.xcodeproj)
plugin/                      TypeScript Cordis bundle (apply + dsh.bundle patch)
themes/                      system, studio-light, studio-dark
docs/                        product.md, theming.md
```

Win / Linux Tauri host is later and is not in this tree. The Mac host and the bundle share the loopback bridge contract above.
