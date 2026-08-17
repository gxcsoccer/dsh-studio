# DSH Studio — macOS 原生宿主（W1）

W1 波次：用原生 SwiftUI 侧栏（`WorkspacesRailView`）替换官方 Web UI 的
`sidebar.workspaces` 插槽，其余 UI 继续由官方 Web 壳渲染。

## 构建与测试

```bash
cd apps/macos
swift build            # 编译 DSHKit / DSHClient / DSHSurface / dsh-studio
swift test             # 140 个测试，全部无头（不需要 dsh runtime、不需要窗口）
swift build -c release # 产出 dsh-studio 可执行文件
```

## 打包成真正的 .app（原生宿主的准入证）

菜单栏、Dock、系统通知、钥匙串、原生文件对话框全部要求进程有 **bundle
identifier** —— 一个裸的 SwiftPM 可执行文件拿不到这些能力，所以 W1 的交付物
必须是 app bundle，而不是命令行产物。

```bash
scripts/package-app.sh              # release 打包 → .build/bundle/DSH Studio.app
scripts/package-app.sh --debug      # debug 打包
scripts/package-app.sh --open       # 打包完直接启动
scripts/window-probe.swift "DSH Studio"   # 「窗口真的在屏幕上吗」的可执行答案
```

脚本做四件事：`swift build` → 组装 `Contents/{MacOS,Info.plist,PkgInfo}` →
`plutil -lint` → ad-hoc `codesign`（没有签名就没有稳定的 keychain / 通知身份）。

- bundle id：`com.gxcsoccer.dsh-studio`
- `Packaging/Info.plist` 是唯一的 plist 来源；版本号由脚本按 git 覆盖
  （`CFBundleVersion` = commit 数，`DSHStudioSourceRevision` = short sha）
- ATS 例外只开给 `127.0.0.1` / `localhost`：数据通道与官方壳都在 loopback 上跑
  明文 HTTP + SSE（bridge-contract.md §2）。**不加 `NSAllowsArbitraryLoads`** ——
  那等于把整个 WebView 的传输安全关掉。

**没有 .xcodeproj 是刻意的**：依赖方向是本项目最重要的架构不变量（ADR-0002），
它由 `Package.swift` 的 target 图 + 源码扫描测试守着。Xcode 工程会把这张图复制
一份到 `swift test` 看不见的地方，两份迟早不一致。

### 没有 runtime 时怎么起

```bash
# 已有官方 dsh 在跑，但 studio profile 还没接上时的逃生阀：
DSH_STUDIO_SHELL_URL=http://127.0.0.1:3080 "DSH Studio.app/Contents/MacOS/dsh-studio"
```

没有 `bridge.json` 也不会白屏：右半屏显示原生「与 runtime 失联」面板（含下一步
命令），后台每 3s 重试一次，runtime 起来后自动接上（bridge-contract.md §2.3
点名要求宿主能显示失联态）。

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
| G-3 运行期心跳失联 → 撤下原生插槽 | `DSHSurface/SurfaceHeartbeat.swift`、`SurfaceCoordinator.startHeartbeat()` | `SurfaceHeartbeatTests`（9 项：正常 / 丢 1 拍 / 丢 2 拍回落 / 不抖动 / evt 形态 pong / 反向 ping） |
| ADR-0004 官方实现保留为回落 | `NativeSlotHost.handle(.error)` 记账退位、`SurfaceCoordinator.degrade` 撤下全部原生视图 | `NativeSlotHostTests`、`SurfaceCoordinatorTests` |

## 控制通道心跳（known-gaps.md G-3）

握手 watchdog 只覆盖启动期；运行期 client 半半静默死亡时，原生插槽仍然显示但
`slot/invoke` 全部无效 —— **用户点得到、点了没反应**，比白屏更糟。

- 节律：10s 一拍，`req` 预算 5s（契约 §1.5 默认值），连续 2 拍无 pong → 判失联。
- 失联动作与崩溃退位对齐：撤下全部原生插槽视图，官方 Web UI 接管（ADR-0004）。
- 中间态 `suspect`（丢 1 拍）在 UI 上灰化 + 提示，不静默失效。
- 判死后不自动复活：界面不许在两种实现之间抖动。

线上格式（`bridge-contract.md` §1.3 的方法表尚未补这两行，以下是本实现的形态）：

```jsonc
// Native → Web（主格式：§1.3 里 Native→Web 一整列都是 req）
{ "v":1, "t":"req", "id":"01J…", "m":"surface/ping", "p":{ "seq":7, "sentAt":1786951236 } }
// Web → Native（主格式：普通回执）
{ "v":1, "t":"res", "id":"01J…", "ok":true, "p":{ "seq":7 } }
// Web → Native（兼容形态：单向事件）
{ "v":1, "t":"evt", "m":"surface/pong", "p":{ "seq":7 } }
// Web → Native（兼容形态：由 client 半发起，宿主回执并视作活体证据）
{ "v":1, "t":"req", "id":"01J…", "m":"surface/ping", "p":{ "seq":7 } }
```

## 键盘

- `⌥⇧D`：当前插槽 native ⇄ web 热切（不重启、不刷新页面），对照与线上自救通道。
- `⌘R`：重新查找 runtime（重读 `bridge.json`）。
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
- 只有 ad-hoc 签名，没有 Developer ID / 公证 / App 沙箱 entitlements：分发给别人
  仍会被 Gatekeeper 拦。
- 没有 app 图标（`CFBundleIconFile` 未设），Dock 里是默认图标。
- 通知 / 钥匙串 / 原生文件对话框的能力已经解锁（bundle id 就位），但 W1 还没有
  用到它们的功能。
