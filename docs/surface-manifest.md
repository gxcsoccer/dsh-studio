# Surface Manifest — 插槽状态清单

surface manifest 是这套架构的**控制面**：一张 `插槽 → 状态` 的表。它决定 `studio-client` 在启动时往哪些插槽注册遮蔽条目、原生宿主装配哪些视图。

它不是内部实现细节，是**用户可见、用户可改的配置** —— 因为「哪些 UI 用原生」本质上是偏好，不该由我们独裁。

---

## 1. 为什么是配置而不是代码

如果遮蔽哪些插槽写死在代码里，会同时失去三件事：

| 能力 | 靠 manifest 得到 |
| --- | --- |
| **热回退** | 线上出问题改一行配置，官方 UI 立刻回来，不发版 |
| **对照验证** | `mirrored` 态让原生实现跑真实数据而不打扰用户 |
| **用户主权** | 用户能把任何插槽掰回 Web，不用 fork 我们 |

第三条尤其重要。官方 patch 规则是「按 `id` 瞄准配置里的一行并整份替换该行的 config」，所以只要 manifest 是我们插件的 `Config`，用户在自己 profile 的 `cordis.patch.yml` 里就能覆盖它 —— 这是官方给的机制，我们只要不把配置藏进代码就能白拿。

---

## 2. Schema

用 Schemastery 定义（官方校验 + 默认值 + 设置面板自动可视化）。

```ts
// packages/studio-surface/src/config.ts
export const SlotMode = Schema.union([
  Schema.const('web'),       // 官方渲染，我们不注册
  Schema.const('mirrored'),  // 原生隐藏运行，官方渲染（对照期）
  Schema.const('native'),    // 我们以 priority 遮蔽，原生渲染
  Schema.const('retired'),   // 同 native，且官方实现对本产品不再有意义
]).default('web')

export const Placement = Schema.union([
  Schema.const('evacuated'), // 整块离开 Web 布局（默认，优先）
  Schema.const('overlay'),   // 按 rect 悬浮在 WebView 之上（受限）
]).default('evacuated')

export const SlotEntry = Schema.object({
  mode: SlotMode,
  placement: Placement,
  priority: Schema.number().default(-1),      // 遮蔽用；官方默认 0
  keys: Schema.dict(SlotEntrySelf).default({}), // 仅 keyed 插槽
  ids: Schema.dict(SlotEntrySelf).default({}),  // 仅 list 插槽
})

export const Config = Schema.object({
  bridge: Schema.object({
    port: Schema.number().default(43180),
  }),
  surface: Schema.dict(SlotEntry).default({}),
  compareHotkey: Schema.string().default('opt+shift+d'),
})
```

`keys` / `ids` 两个嵌套字段是粒度的来源：`keyed` 插槽按 key 分别配置（一种消息卡片一种状态），`list` 插槽按注册 id 分别配置（只换其中一条，其余官方条目保留）。

---

## 3. 实例

```yaml
# ~/.dsh/profiles/studio/cordis.yml 中 studio-surface 那一行的 config
bridge:
  port: 43180
compareHotkey: opt+shift+d

surface:
  # ── W1 已完成 ────────────────────────────────
  sidebar.workspaces:            { mode: retired, placement: evacuated }
  sidebar.footer.action:
    ids:
      settings-trigger:          { mode: native }     # 只换这一条
      # 其余 list 条目（含第三方）保持官方

  # ── W2 进行中 ────────────────────────────────
  details:                       { mode: native,   placement: evacuated }
  settings.section:
    ids:
      general:                   { mode: native }
      plugins:                   { mode: mirrored }   # 对照中

  # ── W4 对照期 ────────────────────────────────
  conversation.composer:         { mode: mirrored, placement: evacuated }
  conversation.input.model:      { mode: native,   placement: overlay }

  # ── 未开工 ──────────────────────────────────
  conversation.view:             { mode: web }
  root:                          { mode: web }

  # ── keyed 插槽的逐种迁移 ─────────────────────
  conversation.chat.node:
    keys:
      user:                      { mode: native }
      assistant-step:            { mode: mirrored }
      # unknown 永不遮蔽 —— 官方兜底渲染器
  tool.call.toolview:
    keys:
      read:                      { mode: native }
      write:                     { mode: web }
```

这份 YAML 同时是**迁移进度的机器可读快照**：`grep -c 'mode: retired'` 就是完成度。

---

## 4. 解析规则

`studio-client` 收到 `surface/configure` 后按顺序处理，规则要无歧义：

1. **未列出的插槽 = `web`**。默认不动官方 UI。新增插槽（上游加的）自动落到安全侧。
2. `mode: web` → **不注册任何条目**（不是注册一个空组件 —— 那会占掉 cell）。
3. `mode: mirrored` → 注册在**大于**官方的 priority（如 `+1`）：拿到 props 与生命周期，但**不赢渲染权**；原生侧收到 `slot/mount` 但把视图渲染到离屏对照层。
4. `mode: native` / `retired` → 注册在 `priority`（默认 `-1`）赢下 cell；原生侧渲染真身。
5. `keys` / `ids` 的条目**覆盖**父级 `mode`；父级 `mode` 作为未列出 key/id 的默认。
6. 若该插槽声明了子插槽且我们赢下了它，则**必须原样声明全部子插槽**（见 [migration-playbook.md §②](./migration-playbook.md)）。缺一个 → 拒绝该条目并回 `rejected`，**不 partial 应用**。

第 3 条是 `mirrored` 能成立的技巧：用**更高**的 priority 注册反而是「陪跑」—— 官方仍渲染，我们只借生命周期拿数据。这完全在官方语义内，不需要任何额外机制。

第 6 条的「不 partial 应用」很重要：宁可这个插槽整条不生效并大声报告，也不要半生效把 UI 搞成一半原生一半空白。

---

## 5. 热切换语义

`surface/reconfigure` 允许运行时改单个插槽，**不刷新页面、不重启 runtime**：

```
Native → Web  { v:1, t:"req", m:"surface/reconfigure",
                p:{ patch: { "sidebar.workspaces": { mode: "web" } } } }
```

client 侧实现 = 撤销旧的 `ctx.effect` 注册 + 按新 mode 重新注册。因为注册本身是 `ctx.effect` 的可逆副作用，这一步是官方生命周期的自然用法，不是我们发明的热更新。

`compareHotkey`（默认 `⌥⇧D`）就是把当前聚焦的插槽在 `native` ↔ `web` 之间来回翻。它有两个用途：

- 开发期：并排对照原生与官方；
- 线上：**用户自救通道**。原生实现有问题时用户能自己切回去，而不是只能等我们修。

顺带它还是最诚实的验收指标 —— 切回率高就说明原生版更差（见 [migration-playbook.md §⑥](./migration-playbook.md)）。

---

## 6. 与 profile 的关系

manifest 活在 `dsh-studio-surface` 那一行的 `config` 里，因此继承官方全部配置分层：

```
profile cordis.yml            ← 我们发布的默认 manifest
  ↓ 被 profile cordis.patch.yml 覆盖    ← 用户的长期偏好
  ↓ 被 home cordis.patch.yml 覆盖       ← 机器级偏好
  ↓ 被 --patch 覆盖                     ← 一次性实验
```

于是「我不喜欢原生侧栏」是一行用户 patch，不是一个 issue。

验证最终生效的 manifest：

```sh
dsh --profile studio --dump-config
```

---

## 7. 不允许出现在 manifest 里的东西

| 禁止项 | 原因 |
| --- | --- |
| CSS 选择器、类名 | 一旦允许，就回到猜哈希类名的老路（[ADR-0001](./adr/0001-slot-shadowing-over-css-hiding.md)） |
| 像素坐标、宽高 | 几何由 Web 上报（overlay）或原生自主（evacuated），不由配置钉死 |
| 领域数据过滤条件 | 那是产品逻辑，不是插槽状态 |
| `mode: hidden` 之类的第五态 | 「隐藏官方 UI 而不接管」没有正当用例；要隐藏就得有人负责渲染 |

最后一条是刻意的约束：manifest 只能表达「谁来渲染」，不能表达「谁都不渲染」。这堵住了「先把官方 UI 藏起来再说」的懒办法。
