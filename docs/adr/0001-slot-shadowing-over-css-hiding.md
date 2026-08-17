# ADR-0001 — 用插槽遮蔽，不用 CSS 隐藏官方 UI

- 状态：**已采纳**
- 日期：2026-08-17
- 相关：[ARCHITECTURE.md §2](../../ARCHITECTURE.md)、[slot-map.md](../slot-map.md)

## 背景

要「逐个把 Web UI 换成 SwiftUI」，第一个技术问题是：**怎么让官方的那块 UI 不再渲染，把位置让给原生？**

仓库里已有的 `codex/agent-sidebar` 分支给出过一个答案：注入 CSS 把官方侧栏在视觉上抹掉，DOM 节点保留以兼容依赖它的插件。核心手法是覆盖官方框架的 grid 列宽并把侧栏列压成 0：

```css
[class*="_frame"][data-details-collapsed] {
  grid-template-columns: 0px minmax(0, 1fr) 0px !important;
}
[class*="_sidebarCol"] {
  width: 0 !important; max-width: 0 !important; overflow: hidden !important;
}
```

这个方案能跑通，而且在没有更好接缝时是合理的工程妥协。

## 问题

但它依赖三件**官方从未承诺**的东西：

1. **CSS Modules 生成的类名片段**（`_frame`、`_sidebarCol`）。这些是构建产物，上游改个文件名、换个打包配置就变。
2. **DOM 的 grid 布局结构**。上游把 grid 换成 flex，或多包一层容器，选择器立刻失效。
3. **`data-details-collapsed` 这类内部属性**。它是官方组件的实现细节，不是 API。

失效的表现还特别糟：**不是报错，是布局错乱** —— 官方侧栏突然出现在原生侧栏旁边，或者内容区宽度算错。静默的视觉损坏比崩溃更难发现，而且我们在 CI 里几乎无法检测（要截图对比才看得出来）。

对一个明确定位为「不 fork 上游、只用发布的扩展点」的项目来说，这是自相矛盾的：**猜类名哈希本质上就是 fork 了上游的 CSS 实现细节，只是没写进 git。**

## 决定

**改用官方 `ctx.slots` 的 priority 遮蔽机制。**

官方 `packages/client/ui-slots/src/index.ts` 明确规定：

> *Cell shadowing rank (ascending, default 0, lowest renders; same key + same priority throws … register at a different priority to shadow it (lowest renders))*

于是「让官方那块不再渲染」就是：

```ts
ctx.effect(() => ctx.slots.register(
  { name: 'sidebar.workspaces', priority: -1 },
  NativeSlotProxy('sidebar.workspaces'),
), 'studio: shadow workspaces rail')
```

官方组件继续注册在 priority 0，只是不再被 `entriesOfSlot` 选中。

## 理由

| | CSS 隐藏 | 插槽遮蔽 |
| --- | --- | --- |
| 依赖的东西 | 构建产物类名、DOM 结构 | 官方公开的插槽名与 priority 语义 |
| 上游变更时 | **静默视觉损坏** | **编译期/启动期大声失败** |
| 官方组件状态 | 仍在渲染（只是看不见），继续消耗渲染与订阅 | 不渲染，但仍注册 → 干净的回落 |
| 回退成本 | 删 CSS，但布局是否恢复要靠眼睛验 | 改一行配置，机制保证恢复 |
| 粒度 | 只能到「视觉区域」 | 能到 `keyed` 的单个 key、`list` 的单个 id |
| 崩溃保护 | 无 | 官方 `abdicate` 自动回落（[ADR-0004](./0004-keep-official-ui-as-fallback.md)） |

第二行是决定性的。我们**要**上游变更时立刻失败 —— 因为上游是 developer preview，一定会变。会大声失败的依赖可以维护，会静默坏掉的依赖不能。

第五行是意外收益：插槽遮蔽让粒度细到「只把 `user` 类型的消息卡片换成原生」，CSS 方案完全做不到这件事。

## 后果

**接受：**

- 只能替换**官方划出了插槽**的区域。插槽表之外的 UI 细节（某个按钮的内边距）无法遮蔽。
  - 这其实是好约束：它迫使我们以官方的模块边界为迁移单位，而不是以像素为单位。真的需要插槽表之外的调整时，正确动作是给上游提 issue/PR，不是本地 hack。
- 必须承担「声明即占有」的责任：遮蔽声明了子插槽的插槽，得原样声明其全部子槽（见 [migration-playbook §②](../migration-playbook.md)）。

**放弃：**

- 不再写任何 `[class*="…"]` 通配选择器。
- 不再用 `MutationObserver` 守着官方 DOM 重新应用样式。
- CSS 注入的用途**收窄到只做 theme token 变量**（混合期视觉同源，见 [migration-playbook §7](../migration-playbook.md)）—— 注入变量不依赖任何官方结构，是安全的。

**保留的例外：** 无。如果出现「必须靠 CSS 才能达成」的需求，按 [migration-playbook §3](../migration-playbook.md) 升粒度，或者去上游提插槽。
