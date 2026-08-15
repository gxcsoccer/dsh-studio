# 跑起来 / Running it

早期开发构建，未签名。前提：机器上已经能跑官方 DeepSeek Harness（见 [deepseek.com/harness](https://deepseek.com/harness)），并且有 Node ≥ 22.19、pnpm、以及一份可用的模型凭据。

## 一次性：建立 `studio` 组合

```sh
node tools/provision-profile/provision.mjs
```

这会创建 `$DSH_HOME/profiles/studio`，把本仓库的 bundle 链接进去，并**只补装 dsh 安装本身没带的那些包**。

「只补装缺的」是硬要求，不是优化：包会从 dsh 安装自带的共享 `profiles/node_modules` 和 profile 自己的 `node_modules` 两处解析，同一个包在两处出现就会被加载两份。好几个 harness 包用模块局部的 `Symbol()` 做内部查找，两份 `@deepseek-ai/dsh-tools` 会让**每一次工具调用**都死在 `Cannot read properties of undefined (reading 'prepare')`——错误里没有任何东西指向打包。脚本装完会主动检查重复并报错。

**如果你的默认 registry 是内网镜像**，可能拿不到 `@deepseek-ai/*`，或者要挂 VPN。症状是安装中途 ECONNRESET / TLS 错误，不像「包不存在」。绕过：

```sh
node tools/provision-profile/provision.mjs --registry https://registry.npmjs.org
```

看一眼真正会启动的树：

```sh
node "$DSH_HOME/profiles/node_modules/@deepseek-ai/dsh/lib/bin.js" --profile studio --dump-config
```

里面应该有 `studio-runtime` / `webserver` / `frontend-static` 这些行，**不应该**有任何 `dsh-web-app`。

## 跑桌面端

```sh
cd app
./Scripts/make-app.sh
open .build/DSH.app --args --workspace ~/your/project
```

`--workspace` 可以省略——省略时用上次打开的工作区，没有则让你选。应用会自己拉起 `dsh --profile studio`，退出时把它停掉。如果 `:3099` 上已经有一个运行时在答话（比如你自己在终端跑了一个），应用会接管它而不是抢端口，并且退出时**不会**动它。

## 契约层单独跑

`dsh-probe` 是验收探针，也是这个项目的冒烟测试。网关协议没有版本协商，wire 上也读不到契约版本，所以它就是版本检查。

```sh
cd app && swift build

.build/debug/dsh-probe locate       # dsh 在哪、怎么找到的
.build/debug/dsh-probe supervised   # 自己拉起运行时，跑完所有场景，再停掉
.build/debug/dsh-probe session      --url http://127.0.0.1:3099
.build/debug/dsh-probe approval     --url http://127.0.0.1:3099
```

`approval` 那条会真的触发一次沙箱升权，然后**故意不应答就断开下行**，重连验证 rpcId 被逐字重放，再应答并要求这一轮跑完。它会往 `$HOME/.dsh-probe-m1.tmp` 写一个探针文件，跑完可以删。

## 验证

```sh
./check.sh          # codegen → build → 单元测试
./check.sh --live   # 再加一遍对真实运行时的探针（要跑模型，花 token）
```

四层各自抓不同的东西，顺序是按「先炸的那个描述得最准」排的：

| 层 | 抓什么 | 单独跑 |
| --- | --- | --- |
| codegen | 上游改了方法或 schema 命名约定 | `node tools/schema-codegen/generate.mjs` |
| build | 生成的类型和调用点对不上 | `swift build --package-path app` |
| 单元测试 | 录制的真实下行流不再解码成具名分支 | `swift test --package-path app` |
| 探针 | 组合层变了、服务名换了、某个 host 行没了 | `dsh-probe supervised` |

单元测试的核心是 `app/Tests/Fixtures/mux-session.jsonl`——一段**真实录制**的下行流（915 帧，含完整审批往返），被喂回真正的解码路径。它断言的不是「能解码」，而是**没有任何一帧落进 `.unknown`**：`.unknown` 是刻意的容错分支，上游加东西时不会崩，也因此不会有人发现。这一条是唯一能在不起运行时的前提下发现契约漂移的检查。

上游升级之后重新录制：

```sh
node tools/record-fixtures/record.mjs     # 需要一个跑着的运行时
```

录制脚本会自己应答审批，好让 fixture 一直录到 `turn/end`——半路放弃的话，审批之后的帧就全缺了，而那正是最值得覆盖的部分。

## 已知的粗糙处

- **未签名。** 每次重建都是一个新身份，钥匙串会重新问。签名与 Keychain 凭据后端一起，排在后面的里程碑。
- **端口钉死 3099。** 被别的东西占了会启动失败，暂时没有自动换端口。
- **会话界面还是官方 client 插件行渲染的。** 那是[路线 C](../ARCHITECTURE.md#4-ui-策略路线-c) 的中间态：roster 是我们自己组的（没有 `dsh-web-app`），但 chrome 还没换成原生。原生化按 slot 逐个来。
- **`provision` 依赖 pnpm 能连上 registry。** 见上面的 `--registry`。
- **别手动往 profile 里 `dsh plugin add` 那些 roster 包。** dsh 安装大概率已经带了，装进去就是第二份模块实例。走 `provision.mjs`，它会判断该不该装并检查重复。
