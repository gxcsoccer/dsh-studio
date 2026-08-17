# `contracts/` —— 跨语言的 wire golden fixture

这里的每个文件都是**一条真实上线的 payload 字节形态**，由两侧的测试同时读取：

| 文件 | Swift（生产者） | TypeScript（消费者） |
| --- | --- | --- |
| `w1-surface-configure.json` | `apps/macos/Tests/DSHKitTests/SurfaceContractTests.swift` 的 `WireGoldenTests`：断言 `SurfaceManifest.w1Default.configurePayload` 与本文件**逐字段相等**，且反解回 `w1Default` | `packages/studio-client/tests/manifest-golden.test.ts` 的 `describe('the host wire golden…')`：把本文件喂进 `parseManifest` + `planManifest`，断言**零拒绝**且两格都装配 |

## 为什么需要它

known-gaps.md **G-7** 是这套东西存在的理由。当时的状况是：Swift 侧 152 个测试全绿，
TS 侧 199 个测试全绿，端到端却是「原生插槽一个都没出现，宿主回落官方 Web UI」。

原因是两侧各自用**自己手写的 fixture** 做测试：

- Swift 测的是「我的模型能编码成我以为的样子」；
- TS 测的是「我能解析我以为宿主会发的样子」。

两个「我以为」之间差了一个 `keys: {}`（Swift 的非可选字典默认值被合成
`encode(to:)` 写上了线，而 client 半对 `single` 插槽是「keys/ids 存在即拒」），
于是两侧的测试都测不到这条缝。

**结论**：控制通道上每一条会真正上线的 payload，都必须有一份两侧共读的 golden。
测「我以为」测不出跨语言的缝，只有测同一份字节才行。

## 改动规则

1. 改动 fixture = 改动 wire 契约，两侧测试必须同时更新并同时通过；
2. 不要手写 fixture 里的字段来「让测试过」—— 它应当是生产代码**实际产出**的字节；
3. 新增会上线的 payload（例如 `surface/reconfigure` 的 patch）时，在这里补一份，
   并把上表补全。
