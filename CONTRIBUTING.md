# Contributing

DSH Studio is a **carrier, a few host backends, a client roster, and a native client shape** on official `dsh`. It is not a fork of DeepSeek Harness.

先读 [README.md](./README.md)、[ARCHITECTURE.md](./ARCHITECTURE.md)、[docs/product.md](./docs/product.md)。

## Do not

- Do not clone or vendor [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness). Runtime comes from official `dsh`.
- Do not treat an upstream PR as a prerequisite for desktop work. Official docs already say UI is a plugin, and the API gateway already says carriers are ours to write.
- **Do not invent RPC methods or private routes.** 契约是 `RpcMethodMap`。缺能力就加 host 插件注册进已有的域，或走 Typert Remote；不要在 carrier 上开私有路由。原生 chrome 和我们自己的 client 插件之间要说话，走 `DSHSurface` 那条私有通道，不要把 chrome 方法塞进网关。
- **Do not stack `@deepseek-ai/dsh-web-app`,** and do not load `dsh --profile web` in a WebView. 我们组自己的 client roster——[组 roster 和 iframe 是两件事](./ARCHITECTURE.md#4-ui-策略路线-c)。
- **Do not put credentials in process env.** Keychain 走 `CredentialProvider` 后端。
- **Do not poll what streams.** mux / host 是 push 流；轮询是 bug 不是风格。
- Do not start from Electron.
- Do not `inject` a service you never call. 占位依赖会把插件停在 PENDING 而不换来任何东西。
- Do not depend on unpublished APIs. 不在包 `exports` 里的东西不算已发布（例：`dsh-client-connection` 的 `http-bridge` 是内部的，`dsh-host-apiproxy` 的 `toFetchHandler` 是导出的）。
- Do not commit `.dsh/`, keychain material, or real session logs.

## Published seams we build on

改动如果依赖了下面之外的东西，请在 PR 里说明理由。

| 面 | seam |
| --- | --- |
| 插件生命周期 | `apply(ctx, config)` · `inject` · `Config` / Schemastery · `ctx.effect()` |
| 网关 | `ctx.apiProxy` · `toFetchHandler` · `AbstractApiClient` / `InProcessApiClient` · `RpcMethodMap` · 四象限信封 |
| 流 | `MuxFrame` / `HostFrame`；`approval/requested` 与 `question/requested` 必须经 `/api/respond` 应答 |
| 会话 | `session/event` 日志 · 投影（`session/projection`） |
| Agent | `ctx.agents` · `agent.inject()` · `dsh-agent-presets` |
| Host 后端 | `CredentialProvider` · `DirectoryPicker` 的 `capability()` 联合 |
| Client 平面 | `package.json` 的 `dsh.client` · `ctx.slots.register` · SlotMap declaration merging · `SlotRegistry.install` |

## PR order

按 [Roadmap](./ARCHITECTURE.md#5-roadmap) 走，欢迎顺序如下：

1. **M0 — Swift 协议层**：四象限信封、rpcId、WebSocket 下行、`tools/schema-codegen`。先打现有 `:3080`，零 Node 代码。
2. **M1 — 审批与提问闭环 + 进程监督**。前者不是 UI 打磨，是「agent 不卡死」的正确性问题。
3. **M2 — `studio` bundle 与 chrome**：自组 client roster（[要复刻什么](./ARCHITECTURE.md#29-自组-surface-bundle实际要复刻什么)）、自写 layout 插件、SwiftUI 窗口 / 侧栏 / 命令面板 / 通知 / 首次运行 / 空状态 / a11y。**这一阶段保留 loopback webserver。**
4. **M3 — 逐 slot 原生化**，从 composer chain 开始。一个 slot 一个 PR。
5. **M4 — carrier 与 host 后端**：`dsh-carrier-macos`（UDS）、Keychain `CredentialProvider`。**只有在客户端平面清空之后**才做，理由见 [§3 何时做](./ARCHITECTURE.md#何时做不是第一个里程碑)。
6. 契约测试与跟踪上游破坏性变更（[§6](./ARCHITECTURE.md#6-跟住一个没有版本号的上游)）。这一类 PR 任何阶段都欢迎，越早越好。

排期上有一条硬规则：**不要提交让仓库处在「旧的拆了、新的还没有」状态的 PR。** 尤其是不要在自组 roster 之前先把 `dsh-web-app` 拆掉。

Keep implementation PRs small. Name the official `dsh` version you tested (developer preview will break). 生成代码（`app/Sources/DSHKit/Generated/`）不手改，改 codegen。

提交前跑 `./check.sh`（codegen → build → 单元测试）。改了协议层就再跑一次 `./check.sh --live`，它会对真实运行时走完整审批闭环。上游升级之后，除了重跑 codegen，还要用 `tools/record-fixtures` 重录一份 fixture——旧录制只能证明旧契约。

## Local

Official `dsh` must already run on your machine ([deepseek.com/harness](https://deepseek.com/harness)). This repo does not need an upstream clone. Mac host needs recent Xcode; the plugins need the Node version official `dsh` requires（当前 ≥ 22.19）。

装好 `dsh` 之后，本机就有一份可读的契约副本——写代码前先查它，比查文档准：

```sh
ls "$DSH_HOME/profiles/node_modules/@deepseek-ai"          # 全部官方包
cat .../dsh-host-apiproxy/lib/types/api/rpc-map.d.ts       # 网关方法全表
cat .../dsh-host-apiproxy/lib/types/api/events.d.ts        # MuxFrame / HostFrame
cat .../<pkg>/README.zh.md                                  # 每个包都有中文 README
dsh --profile studio --dump-config                          # 机器上真正启动的树
```

`$DSH_HOME` 默认是 `~/.dsh`。

Contributions are MIT. Repository copyright: 2026 gxcsoccer.
