# ADR-0002 — 领域数据不经过 WebView

- 状态：**已采纳**
- 日期：2026-08-17
- 相关：[bridge-contract.md](../bridge-contract.md)、[ARCHITECTURE.md §6](../../ARCHITECTURE.md)

## 背景

原生宿主需要会话列表、工作区、消息流、工具调用状态。这些数据的权威来源在 `dsh` 进程里（Cordis 服务 + `session/event` 日志）。

有两条路可以把它们送到 SwiftUI：

- **(A) 借道 WebView**：client 插件读 `ctx.sessions` 等服务，把结果通过 `postMessage` 投影给原生。这是 `codex/agent-sidebar` 分支的做法（它把会话目录 `catalog` 经由 web 通道送给原生侧栏）。
- **(B) 直连 host 插件**：host 半开 loopback，原生直接从 `dsh` 进程取数据，WebView 完全不参与。

(A) 的诱惑很实在：client 插件本来就在 `ctx` 里，`ctx.sessions` 拿来就能用，不需要额外写一个服务端；而且写一次 `postMessage` 比设计一套 HTTP + SSE 便宜得多。

## 问题

(A) 有三个后果，前两个是运行时的，第三个是致命的。

**1. WebView 成了产品的关键路径。**
WebView 会崩、会被系统回收、会在导航/重载时清空 JS 世界。此时原生侧栏连「有哪些会话」都拿不到 —— 而它明明是个原生视图，本不该被网页的死活牵连。更荒诞的是断连场景：Web 崩了的时候，恰好也没法通过 Web 通道告诉原生「Web 崩了」。

**2. 数据要多序列化一轮，且慢在没必要的地方。**
`dsh` → client 插件 → JSON → `postMessage` → 原生。中间那一跳没有产生任何价值，却引入了一次 JS 主线程的排队。流式转录（`assistant-step` 增量）对这一跳特别敏感。

**3. 它把终局变成了重写。**
这是真正的问题。我们的目标是 W7 之后 WebView 不再渲染任何 UI、W8 拆掉它（见 [slot-map.md §8](../slot-map.md)）。如果领域数据借道 WebView，那么「拆掉 WebView」就等于**同时重写所有数据路径** —— 迁移的最后一步会变成风险最高的一步，前面所有的增量、可回退全部作废。

一个以「逐步替换、随时可退」为纲的架构，不能在终局藏一次大爆炸。

## 决定

**采用 (B)。控制通道只承载插槽编排，领域数据一律走 host 半的 loopback 数据通道。**

判据写成一句可以在 code review 里机械执行的话：

> **这条数据在 WebView 被删除之后还需要吗？需要 → 数据通道。**

具体划线：

| 走控制通道（WebView） | 走数据通道（loopback） |
| --- | --- |
| `slot/mount` `slot/unmount` | 会话列表、会话历史 |
| props 快照（折叠态、选中态、宽度） | `session/event` 流 |
| `slot/rect` 几何 | 工具调用状态、工作区、agent 状态 |
| `slot/invoke`（原生动作回灌 Web 注入面） | 一切 apiproxy RPC |
| `slot/error` 崩溃退位遥测 | theme token |

原生侧因此分成两个互不认识的部分：

- `DSHClient` —— 数据通道客户端，**它的代码里不存在 WebView 这个概念**；
- `DSHSurface` —— 控制通道 + 插槽装配，随迁移推进而缩小。

## 理由

- **终局是删代码，不是改架构。** W8 删掉的是 `DSHSurface` 和 client 半；`DSHClient` 一行不动。这让「拆 WebView」从一次心脏手术降级成一次清理。
- **故障隔离。** WebView 崩溃只影响尚未原生化的插槽；已原生化的部分继续从 loopback 拿数据正常工作。断连横幅这种东西终于能可靠地显示了。
- **与官方语义一致。** 官方原则是会话状态以 `session/event` 日志为准（*Model-visible means logged*）。原生端直接消费事件流 = 直接消费权威来源，不做二手投影。
- **`slot/invoke` 是有意留下的窄门。** 有些动作确实只能由 Web 侧的 `ctx` 完成（官方注入面暴露的回调）。这类调用**只传动作与参数，不传数据**，且只允许触达 manifest 里声明为 `native` 的插槽的注入面。

## 后果

**接受：**

- 必须自己写一个 loopback 服务端（HTTP + SSE）、认证、断线重放。这是实打实的额外工作量。
- 原生侧要维护自己的投影缓存与增量合并逻辑，不能白蹭 Web 侧已经算好的视图模型。
- 混合期同一份数据在两侧各有一份投影，可能短暂不一致。缓解：两侧都以 `seq` 为序，UI 上不做跨侧的强一致假设。

**换来：**

- WebView 从「关键路径」降级为「一块正在被替换掉的渲染器」。
- W8 是删除操作，不是迁移操作。

**硬性 review 项：**
每个插槽迁移完成时必须单独确认「控制通道未新增任何领域数据字段」（见 [migration-playbook §5](../migration-playbook.md) 的 DoD 最后一条）。这条守不住，本 ADR 的全部收益都会在几十次迁移里被慢慢磨掉 —— 一次「就这一个字段先走 postMessage 吧」的妥协，就是终局重写的开始。
