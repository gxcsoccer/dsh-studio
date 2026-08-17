# Migration Ledger — 迁移账本

每个插槽迁移完成时追加一行（[migration-playbook.md §⑦](./migration-playbook.md)）。

这份账本有三个具体用途，不是仪式：

1. **上游漂移时的定位表** —— 上游改了某个插槽，一眼看到我们在哪一版对着它写的原生实现；
2. **回退手册** —— 出问题时不用翻代码就知道怎么退；
3. **已知差异的公开记录** —— 原生版与官方版哪里不一样，用户有权知道，不该藏在 commit message 里。

---

## 状态说明

| 状态 | 含义 |
| --- | --- |
| `planned` | 已排波次，未开工 |
| `contract` | 契约已钉（流水线 ①②） |
| `building` | 原生视图开发中（③） |
| `mirrored` | 对照期（④） |
| `native` | 已翻 native，soak 中（⑤⑥） |
| `retired` | 已完成并记账（⑦），官方实现仅作回落 |

---

## 账本

| # | 插槽 | key/id | 波 | 落位 | 状态 | 上游版本 | 开工 | 完成 | 已知差异 | 回退 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| — | _尚无条目。第一条应为 W1 的 `sidebar.workspaces`。_ | | | | | | | | | |

---

## 待办：波次清单

从 [slot-map.md §8](./slot-map.md) 展开，作为账本的开工队列。

### W1 — 侧栏

| 插槽 | 落位 | 状态 | 备注 |
| --- | --- | --- | --- |
| `sidebar.workspaces` | evacuated | `planned` | **第一刀**。先只遮蔽子槽，把 `sidebar` 这一格留给官方 shell，避免继承子插槽声明责任 |
| `sidebar.footer.action` | evacuated | `planned` | `list`，按 id 逐条；第三方条目保持官方 |
| `sidebar.settings` | evacuated | `planned` | 与 W2 的 `settings.*` 合并考虑 |
| `sidebar.workspaces.directoryFlow` | evacuated | `planned` | 原生目录选择器（`NSOpenPanel`）的直接收益点 |
| `sidebar` | evacuated | `planned` | 最后做。做它 = 继承上面三个子槽的声明责任 |

### W2 — 设置与详情

| 插槽 | 落位 | 状态 | 备注 |
| --- | --- | --- | --- |
| `details` | evacuated | `planned` | |
| `conversation.details.tool` | evacuated | `planned` | |
| `settings.section` | evacuated | `planned` | `list`，按 id 逐条 |
| `settings.general.item` | evacuated | `planned` | `list`，按 id 逐条 |
| `settings.header` / `.action` / `.close` / `.trigger` | evacuated | `planned` | 面板骨架，建议一起做 |
| `settings.plugins.tab` | evacuated | `planned` | 只做官方条目；第三方 tab 保持官方 |
| `settings.plugin.item` | evacuated | `planned` | 产品支柱 3（插件管理 UI） |
| `settings.onboarding` | evacuated | `planned` | 产品支柱 4（首次可用） |

### W3 — 会话框架

| 插槽 | 落位 | 状态 | 备注 |
| --- | --- | --- | --- |
| `conversation.session.header` | evacuated | `planned` | 目标：并入 `NSToolbar` |
| `conversation.session.header.actions` | evacuated | `planned` | `list` |
| `conversation.session.header.utilities` | evacuated | `planned` | `list` |
| `conversation.hero.workspace` | evacuated | `planned` | 空态，零风险 |
| `conversation.hero.agentPreset` | evacuated | `planned` | 空态 |
| `conversation.hero.workspace.directoryFlow` | evacuated | `planned` | |
| `shell.overlay` | evacuated | `planned` | `list`，按 id 逐条；不整块接管 |

### W4 — 输入区

| 插槽 | 落位 | 状态 | 备注 |
| --- | --- | --- | --- |
| `conversation.composer` | evacuated | `planned` | **chain takeover**，官方预留动作 |
| `conversation.composer.bar` | evacuated | `planned` | |
| `conversation.composer.dock` | evacuated | `planned` | `list` |
| `conversation.input.dock` | evacuated | `planned` | `list` |
| `conversation.input.left` / `.right` | overlay | `planned` | 过渡态 overlay，随 composer 接管消失 |
| `conversation.input.model` | overlay | `planned` | 同上 |
| `conversation.input.plan` | overlay | `planned` | 同上 |
| `conversation.input.overlay` | evacuated | `planned` | |

### W5 — 转录

| 插槽 | 落位 | 状态 | 备注 |
| --- | --- | --- | --- |
| `conversation.view` | evacuated | `planned` | **本次迁移最贵的一步**。整块撤离，原生从 `session/event` 渲染转录（[ADR-0003](./adr/0003-no-overlay-inside-scroll-containers.md)） |

### W6 — 消息卡片与工具视图（按 key）

| 插槽 | key | 状态 | 备注 |
| --- | --- | --- | --- |
| `conversation.chat.node` | `user` | `planned` | 1 —— 最简单最高频 |
| `conversation.chat.node` | `assistant-step` | `planned` | 2 —— 最核心，流式 |
| `conversation.chat.node` | `tool-call` | `planned` | 3 |
| `conversation.chat.node` | `command` | `planned` | 4 |
| `conversation.chat.node` | `steering` | `planned` | 5 |
| `conversation.chat.node` | `context` | `planned` | 6 |
| `conversation.chat.node` | `compaction` / `manual-compaction` | `planned` | 7 |
| `conversation.chat.node` | `model-retry` | `planned` | 8 |
| `conversation.chat.node` | `turn-error` / `turn-max-tokens` | `planned` | 9 |
| `conversation.chat.node` | `workflow-run` | `planned` | 10 |
| `conversation.chat.node` | `unknown` | **永不遮蔽** | 官方兜底渲染器；原生侧做同款兜底 |
| `conversation.chat.commandview` | 按 key | `planned` | |
| `conversation.chat.turnTail` | chain | `planned` | |
| `conversation.chat.assistant-actions` | `list` | `planned` | |
| `tool.call.toolview` | 按工具 | `planned` | 高频工具优先，长尾走兜底 |

### W7 — 收尾

| 插槽 | 落位 | 状态 | 备注 |
| --- | --- | --- | --- |
| `root` | evacuated | `planned` | 最后一格。遮蔽它 = 必须自己声明 `sidebar` / `conversation` / `details` / `shell.overlay` 四个子槽 |

### W8 — 拆除

| 项 | 状态 | 备注 |
| --- | --- | --- |
| 移除 `studio-client`（client 半） | `planned` | |
| 移除 WebView 与控制通道 | `planned` | |
| 重新评估 [ADR-0004](./adr/0004-keep-official-ui-as-fallback.md) | `planned` | 回落价值随 WebView 归零 |
| 数据通道 | **零改动** | 这就是 [ADR-0002](./adr/0002-domain-data-bypasses-the-webview.md) 换来的东西 |

---

## 漂移记录

上游插槽契约变更记在这里（由 `tools/slot-snapshot` 的 CI 失败触发）。

| 日期 | 上游版本 | 变更 | 影响插槽 | 我们的处置 |
| --- | --- | --- | --- | --- |
| — | — | — | — | — |
