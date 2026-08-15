# DSH Studio

**DeepSeek Harness 的世界级桌面端。**
A world-class desktop for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

不是又一个把官方 Web UI 塞进 Electron / Tauri iframe 的壳。
Not another Electron or Tauri iframe of the official Web UI.

---

## 定位 / Positioning

官方 `dsh` 已经是完整的 Agent 运行时：模型、工具、技能、会话、沙箱、存储、循环、调度、UI 都是插件。社区里已经有人把 `dsh web` 包进桌面窗口——那些项目是有价值的，但它们解决的是「不用自己开终端」：

| 项目 | 实际形态 |
| --- | --- |
| [dataelement/dsh-desktop](https://github.com/dataelement/dsh-desktop) | Electron 托管官方 Web UI |
| [salathleizhang/deepseek-harness-desktop](https://github.com/salathleizhang/deepseek-harness-desktop) | 薄 Electron 壳，监督 `dsh web` 子进程 |
| [bobleer/deepseek-harness-gui](https://github.com/bobleer/deepseek-harness-gui) | Tauri 2 + loopback iframe 嵌官方 GUI |

**DSH Studio 做另一件事：把桌面本身做成一等公民。**

窗口、钥匙串、通知、文件对话框，以及 Mac / Windows / Linux 的 chrome，都是产品表面，而不是浏览器权限提示。Agent 运行时仍然是官方 `dsh`——我们不重写循环，不 vendor 一份 harness，不把官方网页当「应用」。

We are a native desktop product whose UI and OS chrome are first-class, while the agent runtime stays official `dsh`.

## 哲学 / Philosophy

DeepSeek 的设计是 **「一切皆插件」**（Everything is a plugin），内核是 [Cordis](https://github.com/cordiverse/cordis)。桌面端也应该是插件，而不是 fork。

官方 API 网关的包头注释把话说得更直白：

> the API gateway **every client shape shares** … Transport-agnostic by design: this package registers no routes — physical carriers wrap `ctx.apiProxy` themselves.

**在 harness 的世界观里，macOS 客户端不是「壳」，是第四种 client shape。** 官方 Web UI 只是碰巧是第一个。

所以 DSH Studio 是一个 **profile 组合**，而不是一份改过的 `deepseek-ai/deepseek-harness`：

- profile 名：`studio`
- 第一层：官方 [`@deepseek-ai/dsh-base`](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/bundle/base)
- 我们加的三样，每样都是官方已发布的角色：
  - **client shape + roster** — Swift 客户端，加上我们自己列的浏览器插件行。
  - **host backends** — Keychain 凭据、原生通知，按官方 `CredentialProvider` / `DirectoryPicker` 的样板写。
  - **carrier** — 把 `ctx.apiProxy` 经 Unix domain socket 送出进程。官方 web 载体本身就是一个 carrier，所以这是终局的一站，不是起点。

**不 fork [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。**
**不接受「必须给上游提 PR 才能做桌面」这个前提。** 官方已经把 UI 和 transport 都留成了可替换的插件层；我们站在配置层上组合，而不是站在他们的仓库里等合并。

官方入口：

- 源码：<https://github.com/deepseek-ai/deepseek-harness>
- 产品页：<https://deepseek.com/harness>
- 架构参考：<https://deepseek-harness.github.io/deepseek-harness/en/reference/>

## 产品支柱 / Pillars

1. **原生宿主** — 窗口管理、钥匙串、系统通知、原生文件对话框。不是「再弹一个浏览器权限条」。
2. **工作区 + 会话是一等公民** — 打开应用就是打开工作区，会话可恢复、可分叉、可检索；不是「先开一个 URL 再自己找目录」。
3. **插件管理 UI** — 让「一切皆插件」对还没读过 Cordis primer 的人可见、可装、可关、可诊断。
4. **不假设你已经懂 Cordis 的上手** — 第一次打开就能跑起来。profile、bundle、patch 是进阶，不是门槛。
5. **对齐 Codex / Claude Desktop 这一档 agent 桌面端** — 运行态可读、审批可信、产出物是结果、跑歪了能随手拽回来、后台跑完能知道。通用桌面手艺（密度、键盘、空状态、减少运动）是入场券，不是加分项。
6. **MIT** — 和官方 harness 一样开放。

细节见 [docs/product.md](./docs/product.md)。

## 技术栈决策 / Stack

| 层 | 选择 | 明确不选 |
| --- | --- | --- |
| macOS 宿主 | **原生 SwiftUI**（第一优先） | 不要从 Electron 起步 |
| 传输 | 包官方 `ctx.apiProxy`：先用官方 web 载体，终局换 **Unix domain socket carrier** | 不要自造 RPC 路由 |
| Swift 侧类型 | 从官方 **zod schema codegen** | 不要手写 wire 类型 |
| 会话 UI | 自己组 **client roster**，先留官方渲染行，再逐 slot 原生化 | 不要叠 `dsh-web-app`，不要 iframe `dsh --profile web` |
| Windows / Linux | 稍后换一根 carrier 管子，同一份 wire 契约 | 不要为跨平台先做一层网页壳 |

先把 Mac 做成标杆。Win / Linux 复用同一份 `RpcMethodMap` 契约和同一份 `studio` profile，只换传输。

「组 roster」和「iframe 官方 UI」是两件事，这是本项目最容易被误读的一点：前者是自己在 profile 里列浏览器插件行、逐行可换；后者是加载别人组好的成品。见 [ARCHITECTURE.md §4](./ARCHITECTURE.md#4-ui-策略路线-c)。

分层与扩展点见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

## 状态 / Status

早期。DeepSeek Harness 仍是 **developer preview**，核心插件和 API **会有破坏性变更**——网关协议目前**没有版本号**，官方把「独立客户端出现后再加协商」列为延期项。我们就是那个独立客户端，所以类型走 codegen、版本锁死，让上游变更表现为一次编译失败而不是一次运行时错乱。

本仓库跟着官方已发布的扩展点走（`ctx.apiProxy` / `toFetchHandler` / `RpcMethodMap` / `session/event` / `ctx.agents` / `CredentialProvider` / `dsh.client` + SlotMap / `apply` / `inject` / `Config` / `ctx.effect`），而不是锁死一份 fork。

实现按 [Roadmap](./ARCHITECTURE.md#5-roadmap) 的 M0–M4 推进。当前可以本机 dogfood：应用会自己拉起 `studio` 组合、加载我们自己组的 client roster（**不叠 `dsh-web-app`**）、并在 turn 结束或需要审批时发原生通知。会话界面仍由官方 client 插件行渲染——那是路线 C 的中间态，chrome 的原生化按 slot 逐个来。

上手见 [docs/running.md](./docs/running.md)。

## 文档 / Docs

- [docs/running.md](./docs/running.md) — 怎么在本机跑起来
- [ARCHITECTURE.md](./ARCHITECTURE.md) — 分层、`studio` profile、官方扩展点
- [docs/product.md](./docs/product.md) — 首次运行、空状态、无障碍、签名、为何 v1 不做 App Sandbox
- [CONTRIBUTING.md](./CONTRIBUTING.md) — 插件优先，不要去 clone 上游

## 许可 / License

[MIT](./LICENSE) © 2026 gxcsoccer
