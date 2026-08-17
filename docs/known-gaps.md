# Known Gaps — 实现暴露的设计缺口

W1 实现（`packages/studio-client`、`packages/studio-surface`、`apps/macos`）完成后，有十三个缺口是**设计阶段没看出来、写代码才暴露**的。前三个（G-1 ~ G-3）是设计缺口，G-4 / G-5 是**两端联调时才暴露的契约分歧**，G-6 是**只在生产路径上炸、被 140 多个绿灯用例完整掩盖**的并发实现坑，G-7 是**两侧单测全绿却端到端全拒**的跨语言 wire 分歧，G-8 是**把插槽在官方 DOM 里的角色看错**导致的落位方式错误（视觉直接跑偏），G-9 是**「失败必须可见」只做了控制通道一半**、数据通道上把失败画成了空态，G-10 是同一个毛病在 TS 侧的另一张脸 —— **把配置里的默认端口当成观测事实**写进握手文件。

最后三个是**真机 dogfood 才逼出来的**，而且一条比一条更贴近「屏幕在骗人」这件事的本质：G-11 是**测试替身编造了一种真实 bridge 从不产生的 wire 形状**，于是 200 个绿灯掩盖了 100% 失效的真机；G-12 是**bridge 实际发的 SSE 事件名有一半没建模**，被 `.unknown` 无声吞掉；G-13 是**增量根本不足以重建那份列表**，于是快照只拉一次、事件不驱动刷新 —— 链路显示正常、列表却停在启动那一秒。

记在这里而不是埋在 commit message 里，因为它们会影响后续波次的取舍。

每一条都注明：现状怎么绕过的、什么时候必须真正解决、以及是否需要上游配合。

---

## G-1 `slot/rect` 只给几何，不给 z-order 与裁剪祖先 ✅ 已解决（几何携带完整信息 + 纯函数解析）

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

**解决状态（W1）**
`slot/rect` 不再只报一个矩形，而是携带完整信息：`rect` / `clip`（裁剪祖先逐级求交后的可见矩形）/ `viewport` / `scrollable` / `occluded`（`elementFromPoint` 采样）/ `dpr`（契约见 [bridge-contract.md §1.7](./bridge-contract.md)）。宿主侧用纯函数 `SlotGeometryResolver`（`Sources/DSHKit/SlotGeometry.swift`）解析，规则三条、无副作用、可单测（`SlotGeometryTests.swift`）：

- `visibleFrame = frame ∩ clip ∩ bounds`；
- `scale = webViewSize.width / viewport.w`（Web CSS 像素 → 宿主点，不信 `dpr` 单独一个数）；
- `occluded == true` 或可见面积为 0 → **不渲染**（不是画一个错位的视图）。

于是原生视图**能自证「该不该显示、该被裁到多大」**，G-1 的两个缺项（z-order / 裁剪祖先）都有了显式字段。W4 的倾向解法（取消 `input.*` 的 overlay 过渡态、整块撤离 composer）不变 —— 这条只是把过渡期的 overlay 做成**可判定**的，而不是把 overlay 升格成一等落位。

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

---

## G-8 落位方式必须由插槽在官方 DOM 里的真实角色决定 ✅ 已解决（本轮最有价值的发现）

**问题**
`sidebar.workspaces` 此前按 `evacuated`（整块撤离）处理。这是错的：上游 `SidebarRoot.tsx` 里它只是 `.regionArea` **内部的一个 cell**，官方 sidebar 的 header / footer 仍由 Web 渲染 —— 它从来不是一整块区域。

按 `evacuated` 处理的后果是两处叠加的形变：

1. 原生栏被放成 WKWebView 的**兄弟列**，把 Web 内容整体右推约 225px；
2. Web 侧留下的占位符是裸的 `visibility: hidden` div，在 flex column 里**塌缩成约 0 高**，于是原生栏只剩约 150px 高、文字被裁切。

用户看到的「很丑 + 没和 Web 对齐」就是这两条的合成结果。

**解决状态（W1）**
WebView 占满内容区，原生视图以**受控 overlay** 精确覆盖 Web 让出的那块 rect（`NativeSlotLayer` = WebView 的 `.overlay`，几何按 G-1 的解析结果）。

**留下的规律（比修复本身更重要）**
> **落位方式必须由该插槽在官方 DOM 里的真实角色决定，不能凭「它看起来像一整块区域」来推断。**

判据是读上游的 JSX/CSS：它是某个容器的**唯一子树**才可能 `evacuated`；它只是容器里的一个 cell（还有兄弟由 Web 渲染）就只能 overlay。

**overlay 与 ADR-0003 如何共存**
[ADR-0003](./adr/0003-no-overlay-inside-scroll-containers.md) 禁的是**滚动容器内部**的 overlay（漂移是两套渲染管线不共享时钟导致的结构性问题）。本轮把 **「裁剪型 overflow」与「滚动型 overflow」分成两个 bit**：官方 `.regionArea` 是 `overflow: hidden` —— 会裁、不滚。本槽属于裁剪型，没有滚动时钟问题，所以 overlay 合法且不违反 ADR-0003。`slot/rect` 因此分开上报 `clip` 与 `scrollable`，宿主只对 `scrollable: true` 的 overlay 硬拒。区分写在 [ARCHITECTURE.md §4](../ARCHITECTURE.md) 与 ADR-0003 的「执行」一节。

---

## G-9 「失败必须可见」只做了控制通道那一半：数据通道把失败画成了空态 ✅ 已解决（三态读模型）

**问题（本轮修的那个 bug）**
原生侧栏的列表末尾只有两种画法 —— `.empty`（「暂无会话」）与 `.searchStatus`（「无匹配结果」）。于是数据通道的**任何**故障都落在第一种上：

| 真实发生的事 | 用户看到的 |
| --- | --- |
| runtime 没起（`bridge.json` 不在） | 暂无会话 |
| surface 进程被杀 / 端口没人应答 | 暂无会话 |
| bridge token 失效（401） | 暂无会话 |
| 上游把 `workspace.list` 的 `items` 改名（协议漂移） | 暂无会话 |
| 用户真的还没建会话 | 暂无会话 ← **只有这一行是对的** |

「暂无会话」是一句**关于用户数据的断言**，它只有在链路可信时才成立。把它画在一个「根本没拿到数据」的前提上，就是拿一句正确的话去骗人。

**这比控制通道的同类问题更阴险**
控制通道早就做了心跳 + 崩溃退位（G-3）：判死之后**整块**退回官方 Web UI，用户看到的是一个明显不同的界面。数据通道死了却只会安静地说「你没有会话」—— 界面看起来完全正常，用户下一步会去找自己的会话为什么不见了，而不是去看 runtime 是否还活着。

**两个源头，都在「保守兜底」里**

1. 视图层：空态判据是 `列表.isEmpty`，一个**只关于行数**的判断，回答不了「凭什么敢说空」；
2. 数据层：快照解码写成 `try? … ?? WorkspaceListValue(items: [])`，于是协议漂移被翻译成「零个工作区」，而 `link` 还停在 `.live` —— **静默降级成空态**，正是失败不可见的教科书写法。

**解决状态（W1）**

- **判据搬出视图**：新增 `DataAvailability`（`RuntimeLink.swift`）四态读模型 —— `pending` / `unavailable(reason:retryable:)` / `empty` / `populated`，由 `DSHClient.dataAvailability` 纯函数算出。顺序是「有行 → populated；无行且失败 → unavailable；`.live` 且拿到过快照 → 才敢说 empty；否则 pending」。视图只 `switch`，自己不推理（W2 的下一个列表照抄这个 switch）。
- **失败原因可诊断**：`DisconnectReason` 从 4 个 case 扩到 9 个，判据是**下一步不同才分家**（`remedy` 一栏）—— `runtimeNotRunning` / `surfaceUnreachable` / `unauthorized` / `insecureDescriptor` / `timedOut` / `protocolBroken` / `transport` / `streamEnded` / `cancelled`，每个带稳定的机器可读 `code`（日志与测试都用它，不 grep 中文文案）。
- **解码不再宽容**：`WorkspaceListValue` / `SessionListValue` 的 `items` 必须存在，缺失就抛 → `.protocolBroken`。`archivedSessionIds` 这类**后加的可选字段**仍然容错（「没有归档」与「不知道有没有归档」在渲染上同义），宽容只用在这种地方。
- **有节制的重试**：指数退避 + `maximumBackoff` 封顶 + `stabilityWindow`（一次连接活满 5s 才把退避计数归零，否则「连上就断」的 runtime 会让退避形同虚设），外加用户可点的手动重试 —— 这是 `unauthorized` 这类不可重试失败**唯一**的复活路径。
- **UI 三态分开画**：失败态用既有 token（`errorPrimary` / `businessPrimary` / `labelTertiary` / `empty` / `meta`）+ 上游 `.empty` 的排版盒，说清是连接问题并给一颗重试；空态保留原样；「正在连接」自己是一态。列表已经画了失败态时**不再叠横幅**（同一句话说两遍反而更难读）。
- 回归网：`DataChannelAvailabilityTests.swift`（21 条）+ 两条源码守卫（凡是写「暂无…」的视图必须 switch `dataAvailability`；`DSHKit`/`DSHClient` 不许用 `try? … ?? []` 把解码失败兜成空表）+ 离屏渲染的空/失败态 PNG 并排对照（`--render-slot-snapshots`）。

**留下的规律（比修复本身更重要）**

> **「失败必须可见」必须同时覆盖控制通道与数据通道，只做一半等于没做。**

因为用户看的是**一块屏幕**，不是两条通道。控制通道做得再严，只要另一条通道能把故障渲染成一句正常的话，那块屏幕整体上仍然会骗人 —— 而且骗得更彻底：界面看起来完全健康，连「有点不对」的直觉都不给。

推论有两条，已经反写进 [ARCHITECTURE.md §6](../ARCHITECTURE.md)：

1. **每一条会渲染成「什么都没有」的路径，都必须能回答「我凭什么敢说没有」。** 空列表、空详情、零计数，都是关于数据的断言，前提是链路可信；判据要住在数据层的读模型里，而不是视图的 `isEmpty` 上。
2. **`try? … ?? 空值` 是失败可见性的头号敌人。** 它把「读不懂」变成「没有」，而这两者在屏幕上恰好长得一样。宽容解码只允许用在**后加的可选字段**上，绝不允许用在列表主体上。

---

## G-10 `bridge.json` 的 `webUrl` 把配置默认端口当成观测事实 ✅ 已解决（问真正持有 socket 的那个服务）

**问题**
`profiles/studio/cordis.patch.yml` 里写着 `shellUrl: http://127.0.0.1:3080` —— web bundle 的**默认**端口，被当成事实抄了一遍。而 `scripts/dogfood.sh` 用 `--port 3081` 起 runtime。于是握手文件长这样：

```json
{ "port": 43180, "webUrl": "http://127.0.0.1:3080", "pid": 7176 }
```

数据通道走 43180，所以侧栏没炸；但 `webUrl` 指着一个**没人监听的端口**。宿主把它加载进 WKWebView 会得到一片空白，而且**既不重试也不诊断** —— 因为「地址存在」把两条兜底路径（重新发现 + 「runtime 未运行」提示）都关掉了。

**为什么没人发现**
`scripts/dogfood.sh` 自己 `export DSH_STUDIO_SHELL_URL=http://127.0.0.1:$PORT`，而环境变量在宿主侧**优先级更高**。也就是说：唯一有人真的去看的那次运行，恰好是这个错值伤不到人的那次运行。

**根因不是打错字，是把「配置」当成了「观测」**
`webUrl` 被建模成纯配置，理由写得也很像样：「浏览器该用哪个地址由 web bundle 的 `webserver` 行、反向代理、SSH 隧道共同决定，插件无从得知」。前半句错了 —— 进程内部**恰好**知道自己 bind 在哪：`webServer` 服务持有那个 socket，它的 `port` getter 报的是 `listen` 之后的实际端口（`port: 0` 时是 OS 分配的那个）。只有反代/隧道/容器映射才真的不可观测。

**解决状态（W1）**

- 新增 `packages/studio-surface/src/shell-url.ts`：`resolveShellUrl` —— **显式配置 > 实际监听的 carrier > 什么都不发**。函数体内不存在任何编译期默认端口。`0.0.0.0` / `::` 这类 bind 通配符翻译成 loopback（原生宿主与 runtime 必然同机），因为通配符不是一个可连接的地址。
- `webServer` 通过 `ctx.inject(['webServer'], …)` 取（上游对**可选**依赖的写法），**不是** `export const inject`：数据通道不许等 Web 壳（ADR-0002），没有浏览器载体的组合（Electron 走 `file://`）照样要有侧栏。
- 插件体搬到 `plugin.ts` 并把 gateway 适配器变成参数，于是「发布哪个地址、什么时候发布」这件事**可从测试到达**（`index.ts` 仍是唯一 import 上游的组装根）。carrier 早到 / 晚到都能得到一份正确的文件（晚到就**原地重写** `bridge.json`，宿主每次重连与每 3s 的壳发现都会重读它）。
- profile 里的 `shellUrl` 删掉，并留注释说明「只在客户端到不了 carrier 自己的地址时才配」；`scripts/dogfood.sh` 不再 export `DSH_STUDIO_SHELL_URL`，让分歧可见。
- 用例：`shell-url.test.ts`（7 条，含「任何输入都不许算出 3080」）+ `handshake.test.ts`（5 条，钉住 wiring：不等 carrier、早到/晚到、显式配置胜出、卸载后晚到的 carrier 不许把文件复活）+ `profile.test.ts` 一条源码守卫（profile 不许再写 `shellUrl`）。
- 剩下一处**已知的检查不到**：`AssertHostContextFits` 对 `webServer` 是空判（可选成员 + 提供方不在本程序里），所以上游改名不会变成编译错误。补偿是这条降级**在运行期可见**：`inject` 不触发 → 不发 `webUrl` → 宿主打印「bridge.json 里没有 webUrl」并继续重新发现，而不是加载一个错页面。理由写在 `host-context.ts` 头部。

**留下的规律**

> **一个猜出来的地址比没有地址更糟。** 缺失会触发兜底与诊断，错值会把两者都关掉。

以及它与 G-9 是**同一条**规律的两张脸：G-9 是「没拿到数据却说没有数据」，G-10 是「没观测到端口却说端口是几」。都是**在没有依据的地方给出一个自信的答案**，而两次的正确做法都一样 —— 问真正知道的那一方，没人知道就闭嘴，并让「闭嘴」这件事可见。

---


它们都指向同一个判断偏差：**我在设计时把 overlay 和「父原生 / 子 Web」这类混合形态想得太可行了。**

实现暴露出来的规律是：

> **混合形态的成本远高于整块撤离。** 每一次「先做一半」的过渡态，都需要额外的协议字段、额外的失效判定、额外的降级路径。

所以三条缺口的倾向解法惊人地一致 —— **都是取消过渡态、直接跳终态**：

- G-1 → 不做 overlay 过渡，W4 直接整块撤离 composer；
- G-2 → 不做「父原生子 Web」，父槽接管必须自下而上；
- G-3 → 不做「半死不活」，控制通道失联即整体回落官方 UI。

这条规律已反写进 [ARCHITECTURE.md §4](../ARCHITECTURE.md)：**evacuated 是一等落位，overlay 不是「另一种选择」而是「例外」，且每个 overlay 都必须可判定（G-1 的几何字段）并有明确的消失计划。** G-8 补上了另一半：**例外用在哪里，由插槽在官方 DOM 里的真实角色决定，不由观感推断。**

---

## G-11 测试替身编造了一种真实 bridge 从不产生的 wire 形状 → 200 个绿灯掩盖了 100% 失效的真机 ✅ 已解决（替身必须说线上那句话）

**问题**
真机一启动，侧栏就是一句红字：

```
data channel down [protocol-broken] workspace.list: keyNotFound "items"
```

而 `swift test` 是 200 个绿灯。两边都「对」，因为它们在读**两种不同的协议**：

| | `/rpc` 响应体 |
| --- | --- |
| `FakeTransport`（测试替身编的） | `{ "ok": true, "value": { "items": [...] } }` |
| 真实 bridge（逐字转发上游 `toFetchHandler`） | `{ "type": "server-response", "rpcId": "…", "result": { "ok": true, "value": { "items": [...] } } }` |

`RPCReply.unwrap` 按替身那份写的，于是真机上它把**整个信封**当成了业务值，`WorkspaceListValue` 自然找不到 `items`。

**为什么 G-9 的修复反而让它更响**
G-9 刚把「解不开就抛」立成规矩（不许 `try? … ?? []`）。所以这次漂移没有被静默降级成空态，而是硬邦邦地报了 `protocol-broken` —— 这是**修复起作用**的证据：同样的错，在 G-9 之前会表现为「暂无会话」，只会让人以为自己没建会话。

**根因不是打错字，是替身没有权威来源**
`{ok,value}` 是**上游 `RpcResult` 的内层**，被当成了整个响应体。而 bridge 的 `handleRpc` 只做转发，它不重新包装 —— 也就是说，`server-response` 那一层是 `/rpc` 的**必然**形状，不是可选的。测试替身自己「编」了一个更省事的形状，从此测试与真机就再没交集：**测试测的是替身，不是协议。**

**解决状态（W1）**

- `RPCReply.unwrap` 认三种输入：官方 `server-response` / `client-response` 信封、裸 `{ok,value|error}`（上游内层，仍可能被别的转发面直出）、以及**其余一切 → 抛 `EnvelopeError`**。原来那条「不认识就把它当业务值返回」的兜底删掉了：它正是让整包信封蒙混过关的那一行。
- `EnvelopeError` 归类为 `.protocolBroken` → 侧栏画失败态、日志给出机器可读 code。读不懂信封是**故障**，不是数据。
- `FakeTransport.post` 默认回 `FakeTransport.envelope(_:)`（真 `server-response`）；想测信封本身的用例走 `setRawReplyBody`，**不许**各测试自己编包装。
- 离屏渲染的 `FixtureTransport` 同样改成真信封 —— 截图夹具和线上 wire 脱钩，等于让 PNG 也开始撒谎。
- 用例：`DomainModelTests` 里四条信封解包（官方信封 / 裸 result / `ok:false` / 未知形状必须抛）+ `DataChannelAvailabilityTests` 里「真机信封能走到 populated」「未知信封是 protocol-broken 而不是空态」。

**留下的规律**

> **测试替身是一份协议实现，它必须有权威来源；替身编出来的形状，测试再多也只是自证。**

判据很具体：替身回的每一个字段，都要能在**上游 schema 或真机抓包**里指出出处。做不到就说明这条测试在测自己想象出来的系统 —— 而 G-9 的教训（宽容解码把故障变成空态）之所以能在真机上被立刻发现，恰恰是因为这次没有第二个「善解人意」的兜底。

---

## G-12 bridge 实际发的 SSE 事件名有一半没建模，被 `.unknown` 静默吞掉 ✅ 已解决（按 bridge 真发的东西建模）

**问题**
`bridge-contract.md §2.2` 只写了 `event: session`。而 `bridge-server.ts` 真发的是四种：

| SSE `event:` | 内容 | 原来的下场 |
| --- | --- | --- |
| `session` | 上游 `session/event` | ✅ 已建模 |
| `host` | 宿主级增量 | ✅ 已建模 |
| `mux` | 上游 mux 里**除** `session/event` 之外的一切 —— `session/projection`、`stream/error`… | ❌ 落进 `.unknown` |
| `studio/replay-gap` | 「你要的 seq 出了保留窗口」 | ❌ 落进 `.unknown` |

后果都不是崩溃，而是更坏的东西：会话**标题永远不随实时事件更新**（它走 `session/projection`）；上游明说 `stream/error` 我们当没听见；bridge 明说「你漏事件了，去重新基线」我们继续贴着旧数据宣称 `.live`。

**为什么文档骗了人**
契约文档写的是「协议里有什么」，代码读的是「实现发了什么」。这两份东西一旦不同，**实现赢** —— 而 `.unknown` 兜底让这个分歧完全无声：`unknownFrames` 里默默堆了一串名字，没有任何一处 UI 或断言会因此变红。

**解决状态（W1）**

- `StreamFrame.decode` 按 bridge 的真名分派，`mux` 再按内层 `type` 二次分派：`session/projection` → `.projection`、`stream/error` → `.streamError`、其余 → `.unknown("mux:<type>")`（仍然记账，但名字里带得出是哪一种）。
- `studio/replay-gap` → `.replayGap(requested:oldest:)`：**丢掉游标 + 重拉全量**。增量有洞时唯一诚实的动作是重新基线，而不是带着洞继续 live。
- `stream/error` → 抛 `.streamFaulted` 走退避重连，不再记进 `unknownFrames` 了事。
- 用例：三条 wire 级解码（`mux/session-projection`、`mux/stream-error`、`studio/replay-gap` 必须被认出）+ 三条行为级（replay-gap 触发重新基线、stream/error 显式失败、mux 投影真的更新标题）。

**留下的规律**

> **要建模的是「对端实际发什么」，不是「文档说协议有什么」。** 契约文档是意图，`bridge-server.ts` 才是事实；两者不一致时，先按事实建模，再回头修文档。

以及：`.unknown` 兜底是**必要**的（上游是 developer preview，多一种 frame 不该让侧栏停摆），但它是**记账**，不是**处理**。凡是「记账之后什么都不做」的分支，都要能回答一句：如果这一类恰好很重要，我们靠什么发现？

---

## G-13 增量根本不足以重建那份列表，于是快照只拉一次、事件不驱动刷新 ✅ 已解决（事件是失效信号，全量才是真值）

**问题（用户报的第二个 bug）**
链路显示正常，侧栏却始终「暂无会话」。而同一时刻用 bridge token 直接打 RPC，runtime 答得清清楚楚：

```
session.list   → 18 个会话，其中 1 个 blank=false、title="123"、asOfSeq=17
workspace.list → Workspace 的 sessionIds 里含那个非空会话，archived=0
```

也就是说：**该显示的那一行，数据早就在 runtime 里了，只是原生侧栏手上那份快照是启动那一刻的。** 全量只在连上时拉一次，之后完全靠增量；而增量**恰好缺**决定「谁该显示」的两个事实：

1. `blank` 是上游从会话事件日志折算出来的读模型（`turn/start` 之后才变 false），host 流里**没有任何** frame 宣告它翻转；
2. 会话属于哪个工作区只写在 `workspace.list` 的 `sessionIds` 里 —— 真机抓流确认，新建会话只广播 `host/session-added`，**不发** `host/workspace-changed`。

于是那一行永远进不了列表：`workspace.sessionIds` 里没有它，`blank` 也还是 true。

**这和「把失败画成空态」是同一种病**
G-9 修的是「没拿到数据却说没有数据」。这次是「拿到过数据，之后再也没更新，却继续把它当现状」。屏幕上同样是一句无法保证的断言，而且**更难发现**：界面不仅正常，还「有内容」，只是内容停在了过去某一秒。

**解决状态（W1）**

- **每次连接与重连都重新拉全量**，续传照样拉（`Last-Event-ID` 仍然带上，不丢事件）。省下的那两个 loopback RPC，换来的是一份可能永久错误的列表 —— 不值。
- **事件降级为「列表失效信号」**：`host/*`（含没建模的类型）、`turn/start`、`userMessage`、`replay-gap`、**解析失败的帧**，都只表示「有事发生」，具体新值一律回头问 `workspace.list` / `session.list`。一个 chunk 里的多帧**合并成一次**刷新（新建会话一次来 5~6 帧，不该打 5 遍 RPC）。
- **`agent-error` 不触发刷新**：它只改横幅文案，不改列表成员 —— 失效判定要精确到「哪些事实变了」，否则退化成对着 loopback 轮询。
- **全量与增量的对齐规则按字段定权威**（`reconcile(row:)`），依据是上游各字段的**来源**：`running` 读的是 `agent.status`（请求那一刻的活进程状态）→ 无条件听全量；成员关系只有全量有 → 只认全量；`blank` 与投影是事件日志折算的、行里带 `projections.asOfSeq` → 和我们应用到的 seq 比，**高者胜**。少了这条规则，全量会把刚从 `session/projection` 收到的标题擦掉（表现为「标题闪一下就没了」）。
- **过期不再冒充现状**：`DataAvailability` 增加 `.stale(reason:retryable:)`。有行 + 链路不在 live → 保留行（清空是另一种撒谎）**并且**在列表末尾明说「以上是最后一次同步的结果，可能已过期」。`isCurrent` 只有 `populated` / `empty` 为真。
- 用例（`DataChannelAvailabilityTests`，全部走真 SSE 文本 + 真信封）：会话变更事件 → 重拉快照 → 新行出现；一个 chunk 多帧只重读一次；解析不了的帧留痕并兜全量；未建模的 host frame 也触发重读；流断开 → `.stale` 且 `isCurrent == false`；SSE 重连成功 → 重新对齐全量；真实数据 fixture（15 个 sessionIds / 14 blank / 1 个 title="123"）→ 侧栏**恰好**一行 `123`。

**真机端到端复现与验证（2026-08-18，日志见 `g13-verified.log`）**

用户报的那一幕被完整重演了一遍：全新的 `DSH_HOME`（零会话）+ runtime `127.0.0.1:3082`，app 起来时确实是**空**，然后在 **app 运行期间**用 bridge token 造出一个非空会话（`session.create` → `session.prompt "123"`，`blank` 由 true 翻成 false、`title=123`、`asOfSeq=16`）。原生栏自己刷出来了：

```
02:10:02  snapshot #1: 0 workspace(s), 0 session(s), 0 displayable
02:10:02  availability pending → empty (link=live, displayable=0, snapshots=1)
02:10:20  host/session-added → re-reading the snapshot
02:10:20  snapshot #4: 0 workspace(s), 1 session(s), 0 displayable   ← 还是 blank，正确地不显示
02:10:48  host/session-status → re-reading the snapshot
02:10:48  snapshot #5: 0 workspace(s), 1 session(s), 1 displayable
02:10:48  availability … → populated (link=live, displayable=1, snapshots=5)
```

`empty → populated` 全程没有重启 app，也没有人点重试。中间那两拍（`session-added` 之后仍是 0 displayable）恰好是 `blank` 过滤在起作用的证据：会话建出来但还没说话就**不该**显示 —— 这与官方 UI 一致。

为了让「界面这一刻画的是哪一态」不必靠人对着屏幕转述，`DataAvailability` / `RuntimeLinkState` 各加了一个稳定的 `label`，`DSHClient` 只在**变化时**记一行 `availability A → B (link=…, displayable=…, snapshots=…)`。

**留下的规律**

> **「失败可见」不止于「连不上要说出来」，还包括「数据过期不能装作现状」。**

一份静止的正确数据和一份实时数据在屏幕上长得一模一样，这正是它危险的地方。两条可操作的推论：

1. **增量只有在「足以重建读模型」时才能当真值。** 判据是逐字段问：这个字段的值，能否**只**从事件流推出来？答不上来（`blank`、工作区归属就答不上来）的，事件就只能当失效信号，全量才是真相。
2. **每一处「上次成功读到的数据」都要带上时效性。** 保留旧数据是对的，把旧数据说成现状不是；两者的差别只有一句话的成本。

---

## 待办

- [x] G-3：加 `surface/ping`/`pong` 与运行期失联降级（**W1 上线前**）—— 宿主发起、client 半回答，两端已实现并有测试
- [x] G-2：把「父槽接管必须自下而上」写成 manifest 第 7 条规则并在 `manifest.ts` 强制
- [x] G-1：`slot/rect` 携带 `rect/clip/viewport/scrollable/occluded/dpr`，宿主用纯函数 `SlotGeometryResolver` 解析（W4 仍按计划取消 `input.*` 的 overlay 过渡态、整块撤离 composer）
- [x] G-8：落位方式改由插槽在官方 DOM 里的真实角色决定；`sidebar.workspaces` 从 `evacuated` 改为受控 overlay，并把「裁剪型 / 滚动型 overflow」分成两个 bit
- [x] 把「evacuated 是一等落位、overlay 是例外且必须可判定」的结论反写进 ARCHITECTURE.md §4
- [x] G-4：宿主握手后读 `GET /studio/surface` 作为权威 manifest，`w1Default` 退化为兜底（并补齐规则 7 需要的第二行）
- [x] G-5：把「渲染语义」与「启动期必须有实现」分开 —— `retired.mountsNativeView` 保持 `true`，暗槽不要求原生实现（`slotsRequiringNativeView`）
- [x] G-6：时钟缝的默认值改成命名常量，并加运行时回归 + 源码守卫
- [x] G-7：空 `keys`/`ids` 不上线（自定义 `encode(to:)`），并用 `contracts/` 下两侧共读的 wire golden 钉住
- [x] G-9：数据通道的失败必须可见 —— `DataAvailability` 三态读模型、9 类可诊断失败原因、严格解码、退避 + 手动重试、侧栏三态分开画，并用两条源码守卫防复发
- [x] G-10：`webUrl` 改由 `webServer` 服务的实际监听端口推导（`shell-url.ts`），profile 与 dogfood 脚本都不再写死地址
- [ ] G-10 遗留：`AssertHostContextFits` 对 `webServer` 是空判（提供方不在本程序里）。上游若改名，只能靠运行期「没有 webUrl」的日志发现。要变成编译错误，得把 `@deepseek-ai/dsh-host-webserver` 加成 devDependency —— 为两个标量拉一整个 HTTP 载体，等 W2 再权衡
- [x] G-11：`/rpc` 按官方 `server-response` 信封解包，读不懂信封 → `protocol-broken`；测试替身与截图夹具一律回真信封（`FakeTransport.envelope`）
- [x] G-12：按 bridge 真发的 SSE 名建模 —— `mux` 二次分派（`session/projection` / `stream/error`）、`studio/replay-gap` 重新基线
- [x] G-13：事件驱动刷新 —— 每次（重）连都对齐全量、事件降级为失效信号并在 chunk 内合并、全量与增量按字段定权威（`reconcile(row:)`）、新增 `.stale` 让过期数据不冒充现状
- [ ] G-13 遗留：失效信号目前是「相关事件 → 重读整份 `workspace.list` + `session.list`」。会话数量级还小（真机 18 个）时够用；上游若给出「blank 翻转」或「工作区成员变更」的显式增量，这里应当收窄成增量合并，别把 loopback 全量当长期方案
- [ ] G-13 遗留：事件驱动的那次全量刷新途中链路是 `.resyncing`，于是 `dataAvailability` 会短暂落到 `.stale`（真机实测 25~55ms，日志里看得见 `populated → stale(reconnecting) → populated`）。屏幕上看不出来，但语义上「正在刷新」和「链路断了」并不是一回事，应当区分开（例如给 `.resyncing` 带上「是否有活着的流」）
- [x] TS 侧 dogfood 前置条件：`lib/` 真实产物、`profiles/studio` profile、`bridge.json` 的 `host` / `webUrl` 字段（宿主靠它找官方壳，否则只能靠 `DSH_STUDIO_SHELL_URL` 环境变量兜底）
