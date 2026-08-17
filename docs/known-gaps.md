# Known Gaps — 实现暴露的设计缺口

W1 实现（`packages/studio-client`、`packages/studio-surface`、`apps/macos`）完成后，有七个缺口是**设计阶段没看出来、写代码才暴露**的。前三个（G-1 ~ G-3）是设计缺口，G-4 / G-5 是**两端联调时才暴露的契约分歧**，G-6 是**只在生产路径上炸、被 140 多个绿灯用例完整掩盖**的并发实现坑，G-7 是**两侧单测全绿却端到端全拒**的跨语言 wire 分歧。记在这里而不是埋在 commit message 里，因为它们会影响后续波次的取舍。

每一条都注明：现状怎么绕过的、什么时候必须真正解决、以及是否需要上游配合。

---

## G-1 `slot/rect` 只给几何，不给 z-order 与裁剪祖先

**问题**
overlay 落位的原生视图永远在 WKWebView 之上。但 Web 侧上报的 `rect` 只有位置和尺寸，没有：

- z-order —— 该插槽是否被 Web 侧的浮层（tooltip、菜单、`shell.overlay`）遮挡；
- 裁剪祖先链 —— 该插槽是否被祖先 `overflow: hidden` 部分裁掉。

于是原生视图**无法自证「我现在该不该显示、该被裁到多大」**。

**现状绕过**
用 `scrollable` 一刀切：只要检测到滚动祖先就**直接拒绝** overlay（[ADR-0003](./adr/0003-no-overlay-inside-scroll-containers.md)，`NativeSlotHost.swift` 强制执行）。这挡住了最严重的漂移，但**没有解决遮挡问题** —— 一个不在滚动容器里、却被 Web 浮层盖住的 overlay 插槽，原生视图仍会浮在浮层之上。

**何时必须解决**
W4。`conversation.input.left/right/model/plan` 是设计里唯一允许 overlay 的四个插槽，而它们**恰好**会被模型选择器、计划面板这类 Web 浮层覆盖。

**倾向的解法**
不扩 `slot/rect`，而是**取消这四个插槽的 overlay 过渡态**：W4 一次性把 `conversation.composer` 整块撤离，让这四个控件直接变成原生 composer 的内部布局。设计文档已经把它们标为「过渡态，随 composer 接管消失」—— 这个缺口说明**过渡态不该存在，应该直接跳到终态**。

如果确实需要保留 overlay，则需给 `slot/rect` 增加 `clipRect`（祖先裁剪后的可见矩形）与 `occluded: boolean`，由 Web 侧用 `elementFromPoint` 采样判定。成本不低，且每帧都要算 —— 这也是倾向前一种解法的原因。

---

## G-2 manifest 未定义「父插槽被接管时，子插槽的语义」 ✅ 已解决（规则 7）

**问题**
官方 `ui-slots` 的规则是**声明即占有**：注册时用 `children` 声明的子插槽，注册者成为唯一所有者。于是遮蔽一个声明了子槽的插槽时，我们必须原样声明其全部子槽 —— 这一条设计文档写到了（[migration-playbook §②](./migration-playbook.md)）。

但**没写清**的是：父槽被我们接管后，子槽的 `mode` 该怎么解释？

- 父槽 `native`、子槽未列出（默认 `web`）→ 谁来渲染这个子槽？官方组件注册在我们声明的子槽上，可我们的原生父视图里并没有给它留位置。
- 父槽 `native`、子槽 `native` → 两个原生视图的嵌套关系由谁决定？
- 父槽 `mirrored`、子槽 `native` → 语义完全未定义。

**现状绕过**
W1 保守处理：**只接管 `sidebar.workspaces` 子槽，不接管父槽 `sidebar`**，把几何与子槽归属继续留给官方 shell。Swift 侧测试里把这条钉住了（*"W1 兜底 manifest 自身就满足规则 7（bottom-up），且不接管父插槽"*）。

**何时必须解决**
W7 —— 遮蔽 `root` 时无法回避，因为 `root` 声明了 `sidebar` / `conversation` / `details` / `shell.overlay` 四个子槽。届时必须定义清楚：**我们的原生父视图如何为「仍是 web 的子槽」保留一块可嵌入区域。**

**这暴露了一个更深的问题**
「父原生 + 子 Web」意味着要在原生视图内部反向嵌入一块 WebView 区域 —— 也就是从 evacuated 退回 overlay，而且是最坏的一种（原生在下、Web 在上）。

因此更可能的结论是：**父槽的接管必须是自下而上的**，即父槽只有在其全部子槽都已 `native` 之后才允许接管。这条应该写成 manifest 的第 7 条解析规则并在代码里强制。设计文档目前只在波次排序上隐含了这个顺序（`root` 排 W7），但没有把它变成机制。

**解决状态（W1）**
已实现并强制：`manifest.ts` 的 `resolveChildTakeover`（`OWNING_MODES` / `declaredChildrenOf` / `rowOwnership`）在 plan 阶段递归检查每个已声明子槽，任一子槽不归 Studio → 该行整条拒绝，`reason: bad_payload`，detail 指名卡住的子槽。规则文本进了 [surface-manifest.md §4 第 7 条](./surface-manifest.md)，bottom-up 用例进了 `manifest.test.ts` / `client.test.ts`。

副作用值得记一笔：**W1 的 manifest 因此是两行而不是一行** —— `sidebar.workspaces` 要 native，就得先让它声明的 `sidebar.workspaces.directoryFlow` 也归 Studio。父槽 `sidebar` 仍然刻意保持 `web`。

---

## G-3 控制通道没有心跳，Web 侧静默死亡发现不了 ✅ 已解决（宿主发起的 10s 心跳）

**问题**
控制通道只有握手（`surface/ready`）和按需的 req/res。如果 WebView 里的 client 插件**静默死掉**（JS 异常导致事件循环卡死、页面被系统回收但 WebView 实例仍在），宿主不会立刻知道 —— 只能等下一次 `slot/invoke` 或 `surface/reconfigure` 超时（5s）才发现。

在此期间，原生插槽视图仍然显示，但它的 `slot/invoke` 全部无效：**用户点得到、点了没反应**。这比白屏更糟。

**现状绕过**
`SurfaceCoordinator` 有 15s 握手 watchdog（未收到 `surface/ready` → 降级为纯官方 Web UI），但这**只覆盖启动期**，不覆盖运行期的静默死亡。

**何时必须解决**
W1 上线前。这不是后续波次的问题，是现在就能咬到用户的问题。

**倾向的解法**
控制通道加一条 `surface/ping` ↔ `surface/pong`（10s 间隔，2 次未回即判定 client 半失联）。失联后的动作要和崩溃退位对齐：**撤下所有原生插槽视图，让官方 Web UI 接管**（如果 Web 侧真的死了，官方 UI 也不会动，但至少用户看到的是一个明显坏掉的界面，而不是一个看起来正常却点不动的界面）。

同时应该把「原生视图可交互但控制通道失联」这个状态**显式画出来**（灰化 + 提示），而不是静默失效。

**解决状态（W1）**
已实现，两端都在。方向是刻意不对称的 —— **宿主是发起方**：

- 宿主（`SurfaceHeartbeat.swift`）10s 一拍发 `req surface/ping { seq, sentAt }`；
- client 半（`heartbeat.ts`）必须回执 `{ seq, sentAt }`，`evt surface/pong { seq }` 是等价的单向形式，宿主两种都认；
- 丢 1 拍 → `suspect`：原生插槽置灰 + 提示；连续 2 拍无回应 → `lost`：撤下所有原生插槽视图，官方 Web UI 接管，且**判死后不自动复活**。

为什么是宿主发起：要发现的失效恰恰是 client 半自己静默死亡，而死掉的事件循环无法自我上报；宿主是监督方，也是唯一能执行「撤下原生视图」这个动作的一侧。协议表见 [bridge-contract.md §1.6](./bridge-contract.md)。

---

## G-4 manifest 有两个真相源，且宿主那份过不了规则 7 ✅ 已解决（runtime 那份才是权威）

**问题**
[surface-manifest.md §1](./surface-manifest.md) 写的是「manifest 只住在 `studio-surface` 的 `Config` 里，别处没有」—— 因为住在插件配置里才有热回滚、对照运行和用户自决（§6）。但实现下来是**两份**：

- 宿主侧 `apps/macos/Sources/DSHKit/SurfaceManifest.swift` 的 `SurfaceManifest.w1Default`（编译期常量），**它才是真正被 `surface/configure` 下发的那份**；
- TS 侧 `profiles/studio/cordis.patch.yml` 里的 `studio-surface.surface`，只被 `GET /studio/surface` 暴露出去，**没有任何人读**。

而这两份不一致：`w1Default` 只有 `sidebar.workspaces` 一行，规则 7（G-2）要求先接管它声明的子槽 `sidebar.workspaces.directoryFlow`。于是 client 半会把这一行**整条拒绝**：

```
applied: []
rejected: [{ cell: "sidebar.workspaces", reason: "bad_payload",
             detail: "child slot \"sidebar.workspaces.directoryFlow\" … rule 7 is bottom-up" }]
```

**现状（已实测，不是推断）**
`packages/studio-client/tests/bundle.test.ts` 用**真实构建产物** `lib/client.js` 两次驱动同一条通道：profile 里那份两行 manifest → `applied: [directoryFlow, sidebar.workspaces]`；宿主那份一行 manifest → 整条拒绝、官方 occupant 保持在位。也就是说：**协议、构建产物、插件树都是对的，拒绝是契约分歧本身**。

**解决状态（W1）：按解法 1 做，并顺带补齐兜底那份**

1. **runtime 是权威**。宿主收到 `surface/ready` 后，先 `GET /studio/surface`（`apps/macos/Sources/DSHApp/RuntimeManifestSource.swift`，Bearer + 3s 超时），拿到就采纳，`SurfaceCoordinator.manifestOrigin` 记为 `runtimeAuthority`；漂移检测与 `surface/configure` 一律用**采纳后**那份。于是 §1 的「唯一真相源」真的成立，热回滚就是改一行 YAML。
2. **三条路都不致命**：拿不到（runtime 未起 / 404 / token 失效）→ 用编译期兜底（`compiledFallback`）；拿到但它要的原生实现宿主没有 → **拒绝采纳**、留在兜底上（`rejectedRuntime`，用户改错一行 YAML 不该让 app 起不来）；拿到且可实现 → 采纳。
3. **兜底那份也补成合法的两行**：`sidebar.workspaces: native` + `sidebar.workspaces.directoryFlow: retired`，自身满足规则 7。
4. 为什么这段 HTTP 住在 `DSHApp`：`DSHClient` 不许出现 `slot` / `manifest` 字眼，`DSHSurface` 不许出现 HTTP 客户端（ADR-0002，`ArchitectureGuardTests` 逐字扫源码）。`SurfaceCoordinator` 只认一个 `ManifestSource` 闭包缝。
5. 哪份生效**必须能从日志回答**，不靠猜：`SurfaceTelemetry.manifestAdopted(origin:slots:)`，`LoggingSurfaceTelemetry` 以 notice 记一行。

用例：`Tests/DSHSurfaceTests/ControlChannelTests.swift` 的 *"SurfaceCoordinator：权威 manifest 来自 runtime"* 四条（采纳 / 兜底 / 拒绝采纳 / 漂移按采纳后那份判），以及 `Tests/DSHKitTests/SurfaceContractTests.swift` 里 `/studio/surface` 响应解析的用例。

---

## G-5 `retired` 的语义两端不一致：宿主启动自检要求它有原生实现 ✅ 已解决（引入「暗槽」概念）

**问题**
`retired` 与 `native` 的区别按设计**只是意图**（官方实现对本产品不再有意义），不是渲染行为。但两端对「谁要为它准备视图」的理解不同：

- TS 侧：`retired ∈ OWNING_MODES`，注册代理赢下 cell；代理**只有真被渲染时**才向宿主要视图。父槽 native 之后，子槽的 hole 根本不会被渲染，所以子槽 `retired` 不需要任何原生实现。
- Swift 侧：`SlotMode.mountsNativeView` 对 `.mirrored/.native/.retired` 一律为 `true`，而 `NativeSlotHost.verifyImplementations` 在**启动期**就遍历 manifest 检查实现是否存在 —— 于是 `directoryFlow: retired` 会让 app **启动即大声失败**，即使那个 hole 永远不会被渲染。

**结论：不能把 `mountsNativeView` 改成 `false`**
原倾向解法（`retired.mountsNativeView = false`）是错的，核对 [ARCHITECTURE.md §5](../ARCHITECTURE.md) 后推翻：`retired` 的语义是「官方实现作废，**由我们渲染**」。改成 `false` 会让所有**叶子** `retired` 槽（W3 之后的主要形态）不再装配原生视图 —— 那才是真白屏。

**真正的错位在另一处**：错的不是 mode，是「一个槽是否会被渲染」这个判断。规则 7 是 bottom-up 的，所以**每个被接管的父槽都会带一批纯记账的子槽行**；父槽赢下 cell 后官方那棵 React 子树不再挂载，这些子槽的 `renderSlot()` 永不执行 —— 它们是**暗槽（dark hole）**：声明，而非实现。

**解决状态（W1）**
`SurfaceManifest` 增加两个口径（`Sources/DSHKit/SurfaceManifest.swift`）：

- `isDarkHole(_:)`：按插槽名的点号层级找祖先，任一祖先 `ownsRendering` → 这一格永不被渲染；
- `slotsRequiringNativeView`：`mountsNativeView && !isDarkHole`，**启动自检、漂移检测、全拒降级三处共用它**（三处各算一遍必然算歪）。

`SlotMode.retired.mountsNativeView` 保持 `true`，并在 `SlotTypes.swift` 里把「`retired` 与 `native` 的差别是意图不是渲染行为」写进注释。用例：`SurfaceContractTests.swift` 的 *"G-5：retired 仍然装配原生视图"* 与暗槽两条（父槽 native → `directoryFlow` 不要求实现；父槽 web/mirrored → 它重新变成真槽）。

---

## G-6 时钟缝写成默认参数里的 async 闭包 → **生产路径直接 abort** ✅ 已解决

**问题（dogfood 前最后一颗地雷，且是自伤）**
`SurfaceCoordinator` / `ControlChannel` / `SurfaceHeartbeat` / `DSHClient` 的「等一会儿」都走一个可注入的 `sleeper` 闭包，默认值写成默认参数里的闭包字面量：

```swift
sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
```

默认参数表达式在**调用方**上下文求值。当调用方本身在一个 async 任务里（测试体、app 启动的 `Task {}`），这个 async 闭包的 reabstraction thunk 上下文会落在**调用方任务的栈分配器**上；之后闭包被存进对象、在**另一个任务**（握手看门狗 / 超时等待）里 `await` 并释放，Swift 并发运行时直接 `abort()`：

```
freed pointer was not the last allocation
… swift_task_dealloc + 124 in libswift_Concurrency.dylib
… closure #4 in SurfaceCoordinator.start() at SurfaceCoordinator.swift:143
```

**为什么它躲过了 140 多个用例**
所有用例都注入假时钟（那是好习惯，测试不该真睡 15s），于是「不注入时钟」这条**唯一的生产路径**从来没被执行过。而生产代码全部走默认参数：握手一成功、看门狗一被取消，进程就没了。dogfood 时的症状会是「app 启动几秒后直接退出」，不是任何一种可诊断的降级。

**解决状态（W1）**
- 四处默认值改成命名常量：`SystemSleep.duration` / `SystemSleep.seconds` / `SystemClock.now`（新增 `Sources/DSHKit/InjectableClock.swift`，附完整原因说明）；参数类型变成 `SleepFunction?`，`nil` 时在 init 体内取常量。
- 两道防线：
  - 运行时回归 —— *"生产默认构造：不注入假时钟也要能握手"*（`ControlChannelTests.swift`）：一个时钟参数都不传，走完握手到 `live`；
  - 源码守卫 —— `ArchitectureGuardTests` 新增 *"时钟缝不许写成默认参数里的 async 闭包字面量"*，扫四个 target 的每一行。

## G-7 Swift 合成的 `encode(to:)` 把空 `keys: {}` / `ids: {}` 写上线 → **两行全被拒、原生插槽一个都不出现** ✅ 已解决

**问题（真机联调第一次握手就撞上）**
runtime 起在 3081、插件 bundle 200、握手成功、`adopted runtime manifest: 2 rows` —— 紧接着：

```
surface/configure failed: sidebar.workspaces: bad_payload; sidebar.workspaces.directoryFlow: bad_payload
```

两行全被拒，宿主按「我们想接管的每一格都被拒」老实降级，用户看到的是纯官方 Web UI。

根因是一条**跨语言的存在性分歧**：Swift 的 `SlotEntry` 把 `keys` / `ids` 建模成**非可选**字典（读取端好写，不用解包），合成的 `encode(to:)` 于是把 `{}` 也写进 wire；而 client 半 `expandCells()` 对 `single` 插槽的判据是**存在即拒**（`entry.keys !== undefined || entry.ids !== undefined` → `bad_payload`），因为在 `single` 插槽上谈 key/id 本身就说明发送方把插槽种类搞错了。W1 那两行都是 `single`。

**为什么两侧的绿灯都掩盖了它**
Swift 152 个用例、TS 199 个用例全绿，因为两边各测**自己手写的 fixture**：Swift 测「我的模型能编成我以为的样子」，TS 测「我能解析我以为宿主会发的样子」。两个「我以为」之间差了一个 `keys: {}`，缝正好落在两套 fixture 之间 —— 只有端到端会响。

**解决状态（W1）**
- `SurfaceManifest.swift`：`SlotEntry` 自定义 `encode(to:)`，**空表不上线**（`if !keys.isEmpty` / `if !ids.isEmpty`）。语义对四种 slot kind 都成立：`single` / `chain` 上「存在即拒」，`keyed` / `list` 上「空表 = 无覆盖」与省略等价（client 侧 `table ?? {}` 兜底），非空时照常编码。
- 跨语言 golden：新增 `contracts/w1-surface-configure.json` + `contracts/README.md`，**两侧共读同一份字节** —— Swift `WireGoldenTests`（断言 `w1Default.configurePayload` 与它相等、且能反解回 `w1Default`），TS `manifest-golden.test.ts`（喂进 `parseManifest` + `planManifest`，断言零拒绝、两格都装配）。
- 诊断可见性：`ConfigureResult.Rejection` 补 `detail` + `logLine`，`SurfaceError.configureRejected(slot:reason:detail:)` 带上 client 给的人类可读原因 —— G-7 多花一轮排查，就是因为宿主只打印了 `slot: reason`，而 `bad_payload` 涵盖了从键名拼错到规则 7 没满足的一切。

**留下的规律**
`Codable` 的**默认值不等于线上的存在性**。控制通道上每一条会真正上线的 payload，都必须有一份两侧共读的 golden：测「我以为」测不出跨语言的缝，只有测同一份字节才行。

## G-1 ~ G-3 的共同点

它们都指向同一个判断偏差：**我在设计时把 overlay 和「父原生 / 子 Web」这类混合形态想得太可行了。**

实现暴露出来的规律是：

> **混合形态的成本远高于整块撤离。** 每一次「先做一半」的过渡态，都需要额外的协议字段、额外的失效判定、额外的降级路径。

所以三条缺口的倾向解法惊人地一致 —— **都是取消过渡态、直接跳终态**：

- G-1 → 不做 overlay 过渡，W4 直接整块撤离 composer；
- G-2 → 不做「父原生子 Web」，父槽接管必须自下而上；
- G-3 → 不做「半死不活」，控制通道失联即整体回落官方 UI。

这条规律应该反写进 [ARCHITECTURE.md §4](../ARCHITECTURE.md)：**evacuated 是唯一的一等落位，overlay 不是「另一种选择」而是「例外」，且每个 overlay 都必须有明确的消失计划。**

---

## 待办

- [x] G-3：加 `surface/ping`/`pong` 与运行期失联降级（**W1 上线前**）—— 宿主发起、client 半回答，两端已实现并有测试
- [x] G-2：把「父槽接管必须自下而上」写成 manifest 第 7 条规则并在 `manifest.ts` 强制
- [ ] G-1：W4 规划时确认取消 `input.*` 的 overlay 过渡态，直接整块撤离 composer
- [ ] 把「evacuated 是唯一一等落位」的结论反写进 ARCHITECTURE.md §4
- [x] G-4：宿主握手后读 `GET /studio/surface` 作为权威 manifest，`w1Default` 退化为兜底（并补齐规则 7 需要的第二行）
- [x] G-5：把「渲染语义」与「启动期必须有实现」分开 —— `retired.mountsNativeView` 保持 `true`，暗槽不要求原生实现（`slotsRequiringNativeView`）
- [x] G-6：时钟缝的默认值改成命名常量，并加运行时回归 + 源码守卫
- [x] G-7：空 `keys`/`ids` 不上线（自定义 `encode(to:)`），并用 `contracts/` 下两侧共读的 wire golden 钉住
- [x] TS 侧 dogfood 前置条件：`lib/` 真实产物、`profiles/studio` profile、`bridge.json` 的 `host` / `webUrl` 字段（宿主靠它找官方壳，否则只能靠 `DSH_STUDIO_SHELL_URL` 环境变量兜底）
