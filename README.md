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

## 迁移策略 / Migration

不是「一次性重写一个客户端」，而是**以插槽为单位，逐个把官方 Web UI 换成 SwiftUI，直到 WebView 可以被拿掉。**

官方 `dsh` 的 UI 本身就是一张**具名插槽表**（`ctx.slots`，约 35 个插槽，支持 `single` / `list` / `keyed` / `chain` 四种基数）。它规定 `priority` 升序、最小者渲染 —— 所以「换掉官方某块 UI」的正当做法是**在同一插槽上以更低 priority 注册我们自己的条目**，而不是用 CSS 把它藏起来。

由此得到三条纲领：

1. **迁移单位是插槽**，不是像素区域。粒度可以细到「一种消息卡片」（`conversation.chat.node` 是 `keyed`）。
2. **每个插槽的状态是配置**（`web` → `mirrored` → `native` → `retired`），随时可热切回退；官方实现留在原地作为回落，崩溃时由官方 `abdicate` 机制自动接管。
3. **领域数据永不经过 WebView** —— 控制通道只走插槽编排，会话/事件走 host 半的 loopback。于是终局删掉 WebView 是**删代码**，不是重写架构。

| 波次 | 目标 |
| --- | --- |
| W1 | 侧栏（`sidebar.workspaces` 起步） |
| W2 | 设置与详情面板 |
| W3 | 会话标题栏、空态、浮层 |
| W4 | 输入区（官方 `conversation.composer` 预留了 takeover 链） |
| W5 | 转录整块原生化（最贵的一步） |
| W6 | 消息卡片 / 工具视图按 key 收尾 |
| W7 | `root` —— WebView 不再渲染任何 UI |
| W8 | 拆除 WebView，**数据路径零改动** |

完整设计见 [ARCHITECTURE.md](./ARCHITECTURE.md)、[docs/slot-map.md](./docs/slot-map.md)、[docs/migration-playbook.md](./docs/migration-playbook.md)。

## 状态 / Status

早期。DeepSeek Harness 仍是 **developer preview**，核心插件和 API **会有破坏性变更**。本仓库跟着官方已发布的扩展点走（`apply` / `inject` / `Config` / `ctx.effect` / `session/event` / `ctx.agents`），而不是锁死一份 fork。

当前提交只包含宣言、架构与迁移设计。桌面应用实现由后续工作完成。

## 跑起来 / Running the studio profile

Studio 不 fork dsh，也不改官方 `web` profile：它是**同一个官方壳 + 两行插件**。

```sh
npm install
npm run bundle              # 产出 packages/*/lib（tsc → lib/types，tsdown → lib/index.js / lib/client.js）
npm run studio:dump-config  # 只打印合成后的插件树，不启动
npm run studio:web          # 启动 runtime（默认 http://127.0.0.1:3080）
```

三个 `studio:*` 脚本都先跑 [`scripts/studio-home.mjs`](./scripts/studio-home.mjs)：dsh 的 profile 住在 `$DSH_HOME/profiles/<name>`，不是仓库里，所以这个脚本把版本化的 [`profiles/studio/`](./profiles/studio) 连同**构建好的**两个插件安装到 `.dsh-home/`（已 gitignore），再把官方 `dsh` launcher 指过去。插件是**拷贝**而不是软链 —— 软链会让它们从本仓库的 `node_modules` 里解析出**第二份 cordis**，那样插件能挂载但拿不到 `apiProxy`。

profile 的两层 bundle 是官方的 `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app`，我们自己的层只 **insert 两行**（`studio-surface` / `studio-client`），一行官方 `ui-*` 都不 disable —— `npm run studio:dump-config` 与 `dsh --profile web --dump-config` 的行 id 列表逐行相同，只多这两行。manifest 住在 `profiles/studio/cordis.patch.yml` 的 `studio-surface.surface` 里，回滚 W1 就是把它改成 `mode: web`（[surface-manifest.md §6](./docs/surface-manifest.md)）。

macOS 宿主：

```sh
cd apps/macos && ./scripts/package-app.sh && open ".build/bundle/DSH Studio.app"
```

宿主从 `$DSH_HOME/studio/bridge.json` 读端口、token 和官方壳地址（[bridge-contract.md §2.1](./docs/bridge-contract.md) 的字段表）。当前**还差最后一米**：宿主下发的 manifest 只有一行，会被规则 7 整条拒绝，界面回落官方 Web 侧边栏 —— 见 [known-gaps G-4 / G-5](./docs/known-gaps.md)。

## 文档 / Docs

**设计 / Design**

- [ARCHITECTURE.md](./ARCHITECTURE.md) — 分层、`studio` profile、官方扩展点、插槽遮蔽机制
- [docs/product.md](./docs/product.md) — 首次运行、空状态、无障碍、签名、为何 v1 不做 App Sandbox

**迁移 / Migration**

- [docs/slot-map.md](./docs/slot-map.md) — 官方插槽全图、契约、落位与波次
- [docs/migration-playbook.md](./docs/migration-playbook.md) — 单个插槽的七步流水线与验收门
- [docs/surface-manifest.md](./docs/surface-manifest.md) — 插槽状态清单（控制面配置）
- [docs/migration-ledger.md](./docs/migration-ledger.md) — 迁移账本与漂移记录
- [docs/bridge-contract.md](./docs/bridge-contract.md) — 控制通道 / 数据通道协议
- [docs/reference/native-slot-proxy.md](./docs/reference/native-slot-proxy.md) — 核心机制的参考实现
- [docs/known-gaps.md](./docs/known-gaps.md) — W1 实现暴露的设计缺口（含上线前必修项）

**决策 / ADR**

- [ADR-0001](./docs/adr/0001-slot-shadowing-over-css-hiding.md) — 用插槽遮蔽，不用 CSS 隐藏官方 UI
- [ADR-0002](./docs/adr/0002-domain-data-bypasses-the-webview.md) — 领域数据不经过 WebView
- [ADR-0003](./docs/adr/0003-no-overlay-inside-scroll-containers.md) — 滚动容器内部不做 overlay
- [ADR-0004](./docs/adr/0004-keep-official-ui-as-fallback.md) — 保留官方 UI 插件作为回落

**协作 / Contributing**

- [CONTRIBUTING.md](./CONTRIBUTING.md) — 插件优先，不要去 clone 上游

## 许可 / License

[MIT](./LICENSE) © 2026 gxcsoccer
