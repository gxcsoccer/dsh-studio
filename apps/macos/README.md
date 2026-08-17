# DSH Studio — macOS 原生宿主（W1）

W1 波次：用原生 SwiftUI 侧栏（`WorkspacesRailView`）替换官方 Web UI 的
`sidebar.workspaces` 插槽，其余 UI 继续由官方 Web 壳渲染。

## 构建与测试

```bash
cd apps/macos
swift build            # 编译 DSHKit / DSHClient / DSHSurface / dsh-studio
swift test             # 131 个测试，全部无头（不需要 dsh runtime、不需要窗口）
swift build -c release # 产出 dsh-studio 可执行文件
```

工具链：Swift 6.3.3 / Xcode 26.6 / macOS 27.0（`swiftLanguageModes: [.v6]`，严格并发检查）。

## Target 依赖

```
DSHKit      契约层：信封、错误码、插槽类型、manifest、领域模型、JSONValue（零框架依赖）
DSHClient   数据通道：loopback HTTP + SSE，只依赖 DSHKit
DSHSurface  控制通道 + 插槽装配：只依赖 DSHKit（内部 import WebKit）
DSHApp      应用与原生插槽视图：唯一同时认识两条通道的地方
```

`DSHClient` 与 `DSHSurface` **互不认识**。W8 拆掉 Web 壳时删的是 `DSHSurface`
与 `DSHApp/WebContainer.swift`，`DSHClient` 一行不动。该约束由
`Tests/DSHClientTests/ArchitectureGuardTests.swift` 的源码扫描守护（不是靠 review）。

## ADR 的执行点（可执行，不是文档承诺）

| 约束 | 代码位置 | 守护测试 |
| --- | --- | --- |
| ADR-0002 领域数据永不过控制通道 | `DSHSurface/SlotInstance.swift`（`OrchestrationProps.allowed` 白名单）、`DSHSurface/NativeSlotHost.swift:117`（split + 记账） | `NativeSlotHostTests`「白名单外的 props 被丢弃并告警」、`ArchitectureGuardTests` |
| ADR-0003 滚动容器内不许 overlay | `DSHSurface/NativeSlotHost.swift:88`（`scrollable` → 直接抛错）、`DSHKit/SurfaceEvent.swift:142`（缺 `scrollable` 即拒绝，不默认 false） | `NativeSlotHostTests`「滚动容器内的 overlay 直接拒绝」 |
| 握手 15s 未到 → 降级纯 Web | `DSHSurface/SurfaceCoordinator.swift:14`、`:99` | `SurfaceCoordinatorTests`「15s 内没有 surface/ready → 降级」 |
| 未知协议版本 → 拒绝不猜 | `DSHKit/BridgeEnvelope.swift:216`、`DSHSurface/ControlChannel.swift:203` | `BridgeEnvelopeTests`、`ControlChannelTests` |
| 未知上游变体 → `unknown` 兜底 | `DSHKit/Domain/*`（`SessionEventPayload` / `HostFrame` / `StreamFrame` / `SessionOrigin`） | `DomainUnionTests` |
| ADR-0004 官方实现保留为回落 | `NativeSlotHost.handle(.error)` 记账退位、`SurfaceCoordinator.degrade` 撤下全部原生视图 | `NativeSlotHostTests`、`SurfaceCoordinatorTests` |

## 键盘

- `⌥⇧D`：当前插槽 native ⇄ web 热切（不重启、不刷新页面），对照与线上自救通道。
- `⌘⇧R`：重新同步会话快照。
- `⌘N`：新建会话（有官方注入面则走 `startSession`，否则走 `session.create`）。

## 已知契约缺口（实现时遇到、已在代码注释中标注）

1. `bridge.json` 字段表未在 bridge-contract.md 中定义 → 本实现约定
   `{ host, port, token, protocol?, webUrl? }`，并强制 loopback + `0600`。
2. `POST /rpc` 的**响应**包装未定义 → `RPCReply.unwrap` 同时兼容
   `{ok,value}` / `{ok:false,error}` / 裸值三种形态，假设集中在一处。
3. `GET /events` 只定义了 `event: session`，但侧栏还需要工作区变更与标题投影
   → 扩了 `event: host` / `event: projection`，未知 event 名走 `.unknown` 记账。
4. reference/native-slot-proxy.md 示例里的 `session.open` 在上游 `RpcMethodMap`
   中不存在（打开哪个会话是壳的导航状态）→ 走注入面 `selectSession`。

## 尚未实现（留给后续波次）

- `mirrored` 模式只做到「装配但不渲染」，还没有像素/交互对照工具。
- overlay 落位只实现了几何采纳与拒绝，没有做窗口层级合成（W1 用 evacuated）。
- 重命名会话用固定默认名，输入框留给 W2 的表单原生化。
- 没有 App 沙箱 entitlements / 签名配置；`dsh-studio` 目前是 SwiftPM 可执行文件而非 .app bundle。
