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

官方文档对「加 UI / 编辑器集成」的说法很明确：

> drive `ctx.agents` and render from `session/event`

我们按这条路走。DSH Studio 是一个 **bundle + profile**，而不是一份改过的 `deepseek-ai/deepseek-harness`：

- profile 名：`studio`
- 第一层：官方 [`@deepseek-ai/dsh-base`](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/bundle/base)
- 上一层：我们的 surface（原生桌面桥、工作区 / 会话、插件管理 UI）

**不 fork [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。**
**不接受「必须给上游提 PR 才能做桌面」这个前提。** 官方已经把 UI 留成了可替换的插件层；我们站在配置层上组合，而不是站在他们的仓库里等合并。

官方入口：

- 源码：<https://github.com/deepseek-ai/deepseek-harness>
- 产品页：<https://deepseek.com/harness>
- 架构参考：<https://deepseek-harness.github.io/deepseek-harness/en/reference/>

## 产品支柱 / Pillars

1. **原生宿主** — 窗口管理、钥匙串、系统通知、原生文件对话框。不是「再弹一个浏览器权限条」。
2. **工作区 + 会话是一等公民** — 打开应用就是打开工作区，会话可恢复、可分叉、可检索；不是「先开一个 URL 再自己找目录」。
3. **插件管理 UI** — 让「一切皆插件」对还没读过 Cordis primer 的人可见、可装、可关、可诊断。
4. **不假设你已经懂 Cordis 的上手** — 第一次打开就能跑起来。profile、bundle、patch 是进阶，不是门槛。
5. **Linear / Raycast 级的设计质量** — 密度、节奏、空状态、键盘、减少运动。桌面产品，不是套了标题栏的网页。
6. **MIT** — 和官方 harness 一样开放。

细节见 [docs/product.md](./docs/product.md)。

## 技术栈决策 / Stack

| 层 | 选择 | 明确不选 |
| --- | --- | --- |
| macOS 宿主 | **原生 SwiftUI**（第一优先） | 不要从 Electron 起步 |
| 运行时表面 | TypeScript **Cordis bundle plugin** | 不要 fork / 补丁上游源码 |
| Windows / Linux | 稍后用 **Tauri host** 消费同一套 plugin / bridge | 不要为跨平台先做一层网页壳 |

先把 Mac 做成标杆。Win / Linux 复用同一条 `127.0.0.1` 桥和同一份 `studio` profile，而不是再 iframe 一次官方 Web UI。

分层与扩展点见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

## 状态 / Status

早期。DeepSeek Harness 仍是 **developer preview**，核心插件和 API **会有破坏性变更**。本仓库跟着官方已发布的扩展点走（`apply` / `inject` / `Config` / `ctx.effect` / `session/event` / `ctx.agents`），而不是锁死一份 fork。

当前提交只包含宣言与架构。桌面应用实现由后续工作完成。

## 文档 / Docs

- [ARCHITECTURE.md](./ARCHITECTURE.md) — 分层、`studio` profile、官方扩展点
- [docs/product.md](./docs/product.md) — 首次运行、空状态、无障碍、签名、为何 v1 不做 App Sandbox
- [CONTRIBUTING.md](./CONTRIBUTING.md) — 插件优先，不要去 clone 上游

## 许可 / License

[MIT](./LICENSE) © 2026 gxcsoccer
