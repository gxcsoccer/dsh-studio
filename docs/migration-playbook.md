# Migration Playbook — 单个插槽的迁移流水线

这份文件回答一个具体问题：**「把某一个插槽从 Web 换成 SwiftUI」，到底要做哪几步、每步的验收门是什么。**

这条流水线要跑几十遍（见 [slot-map.md](./slot-map.md)），所以它必须便宜、机械、可回退。任何需要「这次特殊处理一下」的插槽，都说明它该被升级到更粗的粒度重做，而不是给流水线开例外。

---

## 0. 前提：三样东西必须先存在

在第一个插槽开工前，这三样是一次性投资，之后每个插槽都白蹭：

1. **`NativeSlotProxy`** — 唯一的通用 Web 侧代理组件（§6）。之后每个插槽的 Web 侧改动都应该是**零行组件代码**，只是 manifest 里加一行。
2. **`NativeSlotHost`** — 宿主侧按 `slot` + `instanceId` 装配 SwiftUI 视图的注册表。
3. **surface manifest + 热切换** — 见 [surface-manifest.md](./surface-manifest.md)。没有热切换，`mirrored` 与回退都无从谈起。

**如果一个插槽的迁移需要改 `NativeSlotProxy`，先停下。** 那说明我们发现了一类新的落位需求，应该先把它归纳进代理组件的能力，再继续 —— 否则代理会长成一堆 if。

---

## 1. 七步流水线

```
① 立契约 → ② 声明责任审查 → ③ 写原生视图 → ④ mirrored 对照
         → ⑤ 翻 native（带开关）→ ⑥ 泡（soak）→ ⑦ 记账 retired
                    ↑                                    │
                    └────────── 任一步不过则回退 ──────────┘
```

### ① 立契约 — 把官方契约钉死

**做什么**

- 从官方源码抄下该插槽的完整契约：`kind`、`scope`、`owner` props、`inject` 面、`keyProps`（若 keyed）、以及它声明的**子插槽**。
- 记录官方占有者是哪个包、哪个组件、当前 priority。
- 把上游版本号（包版本 + commit）写进账本。

**为什么**

`owner` / `inject` 就是这个插槽的交棒面 —— 原生视图要拿到什么、要能回调什么，全在这里。漏一个回调，原生视图就会「看起来对，但按钮没反应」。

**验收门**

- [ ] 契约以 TypeScript 类型形式写进 `packages/studio-client/src/client/contracts/<slot>.ts`，**编译通过**（靠官方的 declaration merging 类型校验，这是免费的正确性保险）
- [ ] `tools/slot-snapshot` 快照已更新并提交

### ② 声明责任审查 — 本流水线最容易出事的一步

**做什么**

回答两个问题：

1. **这个插槽声明了子插槽吗？** 官方 `ui-slots` 的规则是 **「声明即占有」（declaring is claiming）**：注册时用 `children` 声明的子插槽，注册者成为唯一所有者。所以遮蔽一个声明了子槽的插槽，**我们必须原样声明它的全部子槽**，否则其他插件（官方的、第三方的）往那些子槽注册时会抛错 —— 表现为整个 UI 启动失败。
2. **谁在往这些子槽注册？** 用 `slot/probe` 或 `--dump-config` 实测，不要靠读代码猜第三方。

**举例**（W1 的真实陷阱）：`sidebar` 声明了 `sidebar.workspaces` / `sidebar.settings` / `sidebar.footer.action`，而 `ui-workspace` 与 `ui-settings` 都往里注册。直接遮蔽 `sidebar` 而不声明这三个 → 启动即崩。

**决策**

- 子槽多、且有第三方注册 → **降粒度**：先遮蔽子槽而不是父槽（W1 选择先遮蔽 `sidebar.workspaces`）。
- 子槽全是官方且我们准备一次性全接管 → 遮蔽父槽，原样声明子槽并转发给原生。

**验收门**

- [ ] 子插槽清单已列出，每个都有归属决策（自己声明并托管 / 保持官方 / 降粒度绕开）
- [ ] 启动冒烟：遮蔽生效后 `--dump-config` 无 `slot_not_declared`、无 `priority_conflict`

### ③ 写原生视图 — 唯一「真正写产品」的一步

**做什么**

- 在 `apps/macos/Sources/DSHApp/Slots/<Slot>View.swift` 实现视图。
- 领域数据**从 `DSHClient`（数据通道）拿**，不从 `slot/mount` 的 props 拿。props 只用于编排性信息（是否折叠、当前选中、宽度这类 UI 状态）。
- 用户动作分两类：
  - 领域动作（发消息、开会话）→ 走数据通道 RPC；
  - 需要回灌 Web 注入面的动作（调用官方 `ctx.*` 才能完成的）→ `slot/invoke`。
- 视觉必须消费共享 theme token（混合期两侧同源，见 §7）。

**验收门**

- [ ] 视图在 `mirrored` 模式下能用真实数据渲染
- [ ] 键盘可达 + VoiceOver 标签齐全（原生化的意义就在这里，做丢了就白换）
- [ ] 无领域数据经由控制通道（代码评审项，硬性）

### ④ mirrored 对照 — 用真实数据验证，不打扰用户

**做什么**

manifest 里把该插槽设为 `mode: mirrored`：原生视图**隐藏运行**，官方仍然渲染。然后：

- 截图 diff：原生 vs 官方，进 CI（差异不是要求像素一致，而是要求**信息不丢**：条目数、状态、计数、空态文案）。
- 交互对照清单逐项手过：点击、右键、拖拽、键盘、空态、错误态、长内容截断。

**为什么值得多这一步**

`mirrored` 是这套设计花钱买来的东西 —— 它让「原生实现跑在真实会话数据上」不需要用户当小白鼠。跳过它，等于把验证成本转移给线上。

**验收门**

- [ ] 截图 diff 报告已归档，差异逐条有结论（修 / 接受 / 记入已知差异）
- [ ] 交互对照清单 100% 覆盖，无「未测」
- [ ] `slot/error` 计数为 0

### ⑤ 翻 native — 带开关，不带勇气

**做什么**

- manifest 改 `mode: native`（`priority: -1` 生效，遮蔽官方）。
- 保留一个**运行时对照开关**（建议 `⌥⇧D`）：一键在原生/官方之间来回切，不重启不刷新 —— 靠 `surface/reconfigure`。
- 灰度：先内部 profile，再默认。

**验收门**

- [ ] 对照开关双向切换各 10 次，无残留视图、无重复挂载、无端口/监听泄漏
- [ ] 官方条目仍在 priority 0（`slot/probe` 确认），回落路径可用
- [ ] 冷启动、切工作区、断连重连三个场景下该插槽正常

### ⑥ 泡（soak）— 让时间说话

**做什么**

盯三个信号，至少一个完整使用周期：

| 信号 | 来源 | 红线 |
| --- | --- | --- |
| 崩溃退位 | `slot/error` 中 `abdicated:true` | 任意一次即回退调查 |
| 契约漂移 | `surface/ready` 的实测插槽表 vs 编译期快照 | 不匹配即告警 |
| 交互回归 | 用户反馈 + 对照开关的使用率 | 用户频繁切回官方 = 原生实现不合格 |

第三个信号最有意思：**对照开关的使用率是最诚实的验收指标。** 如果用户老是切回 Web，说明我们换的东西更差，别自我说服。

**验收门**

- [ ] 一个使用周期内 `abdicated` 事件为 0
- [ ] 对照开关切回率低于阈值
- [ ] 无新增契约漂移告警

### ⑦ 记账 retired — 迁移的账本

**做什么**

- 账本（[migration-ledger.md](./migration-ledger.md)）追加一行：插槽、上游版本、落位、波次、开工/完成日期、已知差异、回退方式。
- manifest 标 `mode: retired`（语义是「官方实现对本产品不再有意义」，**但仍保留注册作为回落**，见 [ADR-0004](./adr/0004-keep-official-ui-as-fallback.md)）。

**验收门**

- [ ] 账本行已提交
- [ ] 已知差异清单已并入产品文档（不是藏在 commit message 里）

---

## 2. 回退：任何一步都能原路退回

| 阶段 | 回退动作 | 影响面 |
| --- | --- | --- |
| ③④ | 无 —— 用户从未见过 | 零 |
| ⑤ | manifest 改回 `web`（或按 `⌥⇧D`） | 一次配置，不发版 |
| ⑥ | 同上 | 同上 |
| ⑦ | 同上（官方注册一直都在） | 同上 |
| 运行时崩溃 | **无需人工** —— 官方 `abdicate` 机制自动接管 | 该插槽落回 Web，其余不受影响 |

最后一行是本设计的地板：即使我们什么都没来得及做，上游的崩溃退位也保证用户不会看到白屏。这不是我们的功劳，是选择站在官方插槽机制上的红利。

---

## 3. 什么时候该升粒度而不是硬做

出现下面任一情况，**停止本插槽，升级到更粗的粒度重新开条目**：

1. 插槽在**滚动容器内部**，且只能 overlay → 升级到最近的可撤离祖先（[ADR-0003](./adr/0003-no-overlay-inside-scroll-containers.md)）。典型：`conversation.chat.node` → `conversation.view`。
2. 原生视图需要**逐帧**跟随 Web 布局（动画、拖拽 reorder、随内容抖动的高度）→ overlay 必然穿帮，撤离或不做。
3. 需要读 Web 侧 DOM 才能拿到的信息 → 说明契约不够，去 §① 补契约；**绝不允许**用 DOM 查询绕过。
4. 需要新增控制通道方法来搬运领域数据 → 违反 [ADR-0002](./adr/0002-domain-data-bypasses-the-webview.md)，改走数据通道。

第 3 条是硬红线：一旦开始查 DOM，我们就回到了「猜类名哈希」的老路，上游一次重构全部作废。

---

## 4. 每插槽的工作量预期

| 插槽类型 | 预期 | 主要成本 |
| --- | --- | --- |
| 静态 / 空态（`hero.*`） | 半天 | 视觉还原 |
| 表单 / 列表条目（`settings.*`、`sidebar.footer.action`） | 1–2 天 | 状态一致性 |
| 导航树（`sidebar.workspaces`） | 3–5 天 | 大列表性能、键盘、拖拽 |
| 输入区（`conversation.composer`） | 1–2 周 | 输入法、提交语义、附件 |
| 转录（`conversation.view` + 卡片） | 数周 | 流式增量、滚动锚定、卡片长尾 |

这张表的用途不是排期承诺，是**排序依据**：把便宜的先做完，让流水线（`NativeSlotProxy`、`mirrored`、截图 diff、账本）在低风险插槽上磨顺了，再动输入区和转录。

---

## 5. Definition of Done（单插槽）

一个插槽算迁移完成，当且仅当：

- [ ] 契约有类型、有快照、有上游版本记录
- [ ] 子插槽声明责任已处理，启动无 `slot_not_declared` / `priority_conflict`
- [ ] 原生视图键盘可达 + VoiceOver 完整
- [ ] `mirrored` 阶段截图 diff 与交互清单双过
- [ ] 对照开关可双向热切，无泄漏
- [ ] 一个使用周期 `abdicated` 为 0，切回率达标
- [ ] 账本已记，已知差异已公开
- [ ] **控制通道未新增任何领域数据字段**

最后一条每次都要单独确认。它是这套架构能在 W8 干净拆掉 WebView 的唯一保证 —— 每个插槽都守住，终局才成立；漏一个，终局就变成重写。

---

## 6. 附：`NativeSlotProxy` 的职责边界

Web 侧只有这一个组件，它做且只做四件事：

```
mount   → evt slot/mount   { slot, instanceId, key?, scope, props }
update  → evt slot/props   { instanceId, props }        // 浅 diff 后
measure → evt slot/rect    { instanceId, rect, scrollable }  // 仅 overlay
unmount → evt slot/unmount { instanceId }
```

渲染输出按落位二选一：

- **evacuated**：零尺寸、不占位（该区域的屏幕面积由原生 chrome 拥有）
- **overlay**：等尺寸透明占位，撑住 Web 布局；`ResizeObserver` 驱动 `slot/rect`

它**不做**的事（每一条都是有意为之）：

- 不取领域数据（`ctx.sessions` / `ctx.workspaces` 的数据一律不经它手）
- 不缓存状态（状态在原生侧和 host 侧，不在这里）
- 不认识任何具体插槽（没有 `if (slot === 'sidebar')` 这种分支）
- 不查 DOM、不注入 CSS、不猜类名

守住这四条，`studio-client` 就是一个**几百行、可以在 W8 整体删除**的脚手架，而不是第二个前端产品。

---

## 7. 附：混合期的视觉同源

迁移中途必然有一段时间是「原生 chrome + Web 内容」并存。视觉割裂会让用户觉得产品坏了，所以：

- theme token 单一来源（`themes/*.json`），host 半提供，两侧同时消费；
- Swift 侧从数据通道拉 token 构建 `Theme`；WebView 侧由 host 半生成 CSS 变量注入；
- 新增颜色/间距只允许加 token，不允许在任一侧硬编码。

这套机制直接继承 `cursor/design-playground-a785` 分支已经验证过的做法，是混合期的必需品 —— 也是那条分支最值得保留的资产。
