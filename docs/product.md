# Product bar

DSH Studio 要对齐的是 **Codex / Claude Desktop 这一档世界顶级的 agent 桌面端**，而不是「能把官方网页打开」这一档壳。
The bar is a world-class agent desktop, not a successful iframe.

选这个参照系而不是 Linear / Raycast，是因为要解决的问题不同。Linear 那一档的标准是**通用桌面手艺**——密度、节奏、键盘、空状态。那些我们照样要做到，但它们只是入场券。**agent 桌面端真正的难点在别处：一轮工作是分钟级到小时级的，它会动你的文件，它会跑歪，它会同时跑好几个。** 一个交互延迟 16ms 但让你不敢放手的 agent 客户端，是失败的产品；Linear 的评价体系里没有这一项。

对齐它们，是对齐它们**解决的问题和达到的完成度**，不是抄它们的视觉或布局。harness 的模型和它们不一样（preset、goal、plan、subagent、skill、permission preset 都是 harness 自己的概念），照着别人的界面填，会把自己框死在一套不匹配的信息架构里。

这份笔记写的是 *产品标准*。当前仓库还没有实现桌面应用。

一句话澄清，因为这是最容易被误读的地方：**按 [路线 C](../ARCHITECTURE.md#4-ui-策略路线-c)，会话流一开始由官方的 client 插件行渲染，然后逐个 slot 换成原生。这不是 iframe。** iframe 是加载别人组好的成品（`dsh --profile web` 的 `:3080`），你只能在外面加边框；roster 是我们自己列浏览器插件行，逐行可换、可关、可原生化。本文档下面所有的产品标准，对两种渲染方式**一视同仁**——用户不该看出某一块是谁画的。

---

## 世界级意味着什么 / What “world-class” means here

### 这一档 agent 桌面端独有的六条

**1. 等待本身是一个要设计的界面。**
一轮工作是分钟级到小时级的，「它正在跑、我在等」是这个产品最主要的状态，不是加载中的过场。用户随时要能看出：现在第几轮第几步、在调什么工具、烧了多久和多少 token、还能不能拽回来。运行态给一个转圈，就是把最长的那段体验留白了。数据都在——`sessionStats` 投影有 turns / steps / llmMs / toolMs / ttft，`agent/status` 和 host 流有运行态翻转。

**2. 权限是主线剧情，不是设置项。**
用户敢不敢放手，取决于两件事的平衡：它会不会乱动我的文件，以及每次都问烦不烦。审批卡片必须给足上下文，必须能纯键盘一键决定，决定必须能记住，而且事后能翻账——`approval/asked` 和 `approval/decided` 都在仅追加日志里。

「给足上下文」具体是什么，实测过一次才清楚。升权不是沙箱自动弹出来的，是**agent 自己二次发起的**：

1. agent 调 `bash`，沙箱拒绝（`Operation not permitted`）；
2. agent 读到拒绝，**带着 `sandbox_permissions: "danger-full-access"` 和一段自己写的 `justification` 重试同一条命令**；
3. 这次重试才产生 `approval/asked`。

所以审批卡片上必须有三样东西，少一样都是在让用户盲签：**它想要哪个模式**（这是「把沙箱放宽到 danger-full-access」，不是「允许跑一条命令」，两者的份量差得远）、**它自己写的理由**（原文，不要改写）、以及**这是一次被拒后的重试**——刚才被拒的是什么。

真实的一条 reason 长这样，直接给用户看比任何转述都强：

> escalate sandbox to danger-full-access: The user explicitly asked to run this exact command, which writes outside the session workspace to $HOME; full access is the narrowest mode that permits it.

顺带一个测试上的坑：`workspace-write` 限制的是**写**，不是读。拿 `cat` 任何文件都触发不了升权，写工作区外的文件才会。

有一个真实的坑：**用户允许一次 bash 升权之后，策略会被写成 `never`**，后续不再问。这在日志里能看到。客户端必须把这个状态**显性地展示出来**，不能让人在不知情的情况下把门一直开着。「一次同意等于永久同意」而界面上看不出来，是这类产品最严重的信任事故。

**3. 产出物是结果，对话是过程。**
一轮跑完，用户真正要看的是「改了哪些文件、跑了什么命令、diff 长什么样」，不是把三千行流式文本从头读一遍。turn 结束时的产出物摘要是一等内容（官方 `ui-deliverables` 就占在 turn tail 上），不是折叠在某个抽屉里的附属信息。

**4. 中断和转向必须随手可得。**
这是 agent 客户端独有、通用桌面 app 完全没有对应物的交互，也是各家体验差距最大的地方：**它跑歪的第 30 秒，你能不能把它拽回来。**

网关上 `session.prompt` 的 `mode` 有两个值，产品上要区分清楚而不是都做成「发送」：`queue`（排到下一轮）和 `steer`（插到下一步，纠偏）。加上 `session.cancel`，以及 `session.updateQueue` 背后那份可编辑、可删的待发队列快照（`session/queue`）——**待发消息可改可删，本身就是一种「拽回来」**，别只做成一个只读列表。

第三种语义 `agent.inject()`（下一步、不唤醒，正是「把当前文件 / 选区丢给它」该用的那个）**不在网关上**，只在 Node 进程内的 `Agent` 上。原生客户端要这个功能，得先加一个 host 插件把它暴露出来；在那之前只能用 `steer` 近似，代价是会唤醒一个空闲的 agent。这是个已知缺口，不是可以假装已有的能力。

**5. 并发是常态，桌面的优势正在这里。**
多个会话、子 agent、后台 job 同时在跑是默认情况。**不聚焦的会话跑完了，用户要能知道**——通知、dock badge、菜单栏，而不是回去挨个点开看。这正是桌面端相对网页的结构性优势，不用白不用。

**6. 信任来自可回放。**
会话日志是仅追加的权威事实，「它到底干了什么」永远能回放、能导出。原生端不另存一份「权威」记录（见文末）。

### 通用桌面手艺（入场券，不是加分项）

- **Chrome 是我们的。** 标题栏、侧栏、命令面板、通知、文件选择，都按桌面习惯长，而不是浏览器里那一套再套个交通灯。
- **会话是第一场景。** 打开应用就能回到工作区和上一次会话。恢复 / 分叉 / 检索是产品功能，不是「你自己去 Harness home 翻」。
- **插件是可见的。** 「一切皆插件」不能只写在开发者文档里。用户要能看见已装的 bundle、关掉有问题的一层、在失败时得到人话。
- **键盘是完整的。** 命令面板、会话列表、发送 / 取消 / 转向 / 审批 / 切工作区都有快捷键，并且可发现。
- **安静。** 默认不吵。Agent 跑完可以通知；打字时不要抢焦点、不要弹模态——尤其是审批弹窗不能抢走正在输入的焦点。

上半段做不到，就只是个能用的 agent 客户端。下半段做不到，就还是又一个 wrapper——社区里已经有三个了。

---

## 首次运行 / First-run

第一次打开 **不能** 假设用户读过 Cordis primer，也不能把 `cordis.patch.yml` 摊在脸上。

合格的首次运行：

1. **检查环境，用人话讲结果。** Node 在不在、官方 `dsh` 能不能用、**`pnpm` 在不在**（装 bundle 进 profile 要靠它）、工作目录写不写得了。缺什么，给一个动作（安装 Node、安装 `pnpm`、安装 `dsh`、打开官方文档），而不是一段 Cordis 栈。

   顺带一提：**不要假设 `dsh` 在 PATH 上。** 一台正常用着 harness 的机器可能压根没全局装过。解析顺序见 [ARCHITECTURE §5](../ARCHITECTURE.md#5-roadmap)。
2. **创建 `studio` profile，而不是让用户自己叠 bundle。** 第一层是 `@deepseek-ai/dsh-base`，第二层是我们的 bundle。用户此时不需要知道这两个名字。
3. **密钥进钥匙串，不进明文文件、不进仓库、也不进进程环境变量。** 提示来自系统钥匙串，而不是「请 export 一个环境变量然后重启终端」。实现上这是一个 `CredentialProvider` 后端替换掉 `credentials-local`，不是 Swift 侧读了钥匙串再喂给子进程——后者会把凭据泄进进程环境，还会让 `credentials.describe` 说谎。
4. **选一个工作区就开得了会话。** 原生文件对话框。这个不用自己写：官方 `dsh-host-directory-picker-native` 在 macOS 上就是原生选择器，我们只要保证 `-auto` 采样到 native 分支。
5. **失败可逆。** 首次运行做到一半崩溃，再打开不应留下半残 profile 还报内部 id。

不合格的首次运行：克隆上游、手动改 `dsh.profile.bundles`、先解释 fiber / waterfall、把用户送去 `dsh --dump-config`。

进阶（Creator、自己写 plugin、覆盖 patch）可以存在，但必须在第一次成功对话 *之后*。

---

## 空状态 / Empty states

每个主表面都要有空状态，而且空状态本身是动作，不是装饰。

| 表面 | 空的时候说什么 | 主动作 |
| --- | --- | --- |
| 无工作区 | 还没有项目落在 Studio 里 | 打开文件夹 / 从最近的选 |
| 无会话 | 这个工作区还没有对话 | 新会话；可选「把 README 交给 Agent」 |
| 无插件 / 只有 base | 运行时是官方默认能力 | 浏览已装层；不要吓唬人「你缺少生态」 |
| 缺密钥 | 模型还不能走 | 打开钥匙串设置 |
| 密钥被环境变量遮蔽 | 你的 shell 里已经 export 了同名变量，钥匙串写不进去 | 说清楚当前值来自哪一层（`describe()` 会给 `source`）；给「就用环境变量里那个」或「教我怎么取消 export」两条路，别静默失败 |
| `dsh` 不在 | 官方运行时还没装好 | 指向官方安装，保留重试 |
| 一轮跑完但没产出物 | 它这轮只读了代码 / 只回答了问题 | 说清楚它做过什么；不要显示一个空的产出物区让人以为丢了东西 |
| 会话被日志卡死 | 一次工具调用没留下结果，之后每条消息都会被模型服务端拒绝 | 说清楚为什么重试一定失败，并提供「从上一轮完好的地方继续」——`session.fork` 能从干净前缀切一份出来 |
| 会话被上游格式弄破 | preview 破了兼容 | 说明、只读旧日志、开新会话；不要假装能修 |

空状态的文案用产品语言（工作区、会话、插件、密钥），不用实现语言（fiber、row id、waterfall、`SessionEventMap`）。

---

## 无障碍 / Accessibility

v1 就要当一等需求，而不是「以后补 aria」。

- macOS VoiceOver：会话列表、消息流、命令面板、插件开关都可以聚焦、都有标签。
- 完整键盘路径：不依赖指针也能完成首次运行、发一条消息、**批准或拒绝一次升权**、取消一轮、切工作区。审批是主线交互，不能只有鼠标能点。
- 对比度和动态字体跟系统走。
- `Reduce Motion`：关掉非必要过渡；流式输出仍然可读，只是不「飞」。
- 通知可关，并尊重系统勿扰。
- 色不只是信息：错误 / 运行中 / 完成有文字或图标，不单靠红绿。

SwiftUI 宿主应优先用系统控件和 Accessibility API。**路线 C 下有一部分表面由官方 client 插件渲染，它们同样要过 VoiceOver**——「原生那半能读、渲染那半读不了」不算达标，这也是决定某个 slot 该不该提前原生化的依据之一。日后 Tauri 宿主必须对等，不能「Mac 能读、Win/Linux 只能看」。

---

## 签名与分发 / Signing (later)

v1 可以是未签名的开发构建（本地 `swift build` / Xcode Run）。**签名、公证、更新通道是产品的一部分，但不是第一个里程碑。**

之后按这个顺序，而不是一上来就折腾分发：

1. 开发者自己能跑 `studio` profile 和原生窗。
2. Developer ID 签名 + notarization（Mac）；Win / Linux 的等价物跟 Tauri 宿主一起做。
   钥匙串这里有个真实的先后依赖：Keychain 条目的 ACL 绑在签名身份上，未签名的开发构建每次重建都会重新弹授权。开发期这是噪音不是 bug，但它意味着「Keychain 体验合格」这条验收要等签名之后才算数。
3. 自动更新（还是 MIT、还是用户能关）。
4. 只有在 sandbox 策略想清楚以后，才考虑 Mac App Store。见下一节——**Store 不是 v1 目标**。

在此之前，README 必须写清楚：这是 developer preview 上的早期桌面，上游会破，构建可能需要本机已装 `dsh`。

---

## 为何 v1 不做 App Sandbox / No App Sandbox in v1

官方 `dsh` 是本机 Agent 运行时。它需要：

- 拉起 Node（以及工具、子 Agent、有时是沙箱里的 shell）
- 读写真的用户工作区
- 碰 Harness home（profile、会话日志、凭据、插件）

macOS App Sandbox 会切断这些能力，或把它们逼进一堆临时 exception，最后仍然不像沙箱。社区里的 Electron / Tauri 壳也是因为同一原因，把真正的工作交给窗外的 `dsh` 子进程。

v1 选择：

- **Studio.app 不启用 App Sandbox。**
- Hardened Runtime 可以在签名阶段再开，但要一条条审慎声明。
- 我们自己的约束仍然在：carrier 只绑 Unix domain socket（`0600`，不开 TCP 端口）；密钥进钥匙串；不把工作区复制进容器「假装安全」。
- 官方 harness 自己的 sandbox / 审批策略继续管 *Agent 能碰什么*。那是 `dsh-base` 的职责，不是用 App Sandbox 再包一层假安全感。

如果未来要上 Mac App Store，那是另一条产品线（能力会更窄），不是把 v1 塞进沙箱。

---

## 明确不做 / Not in the product

- 加载 `dsh --profile web` 再套个边框。（组自己的 roster 是另一件事，见开头。）
- 抄 Codex / Claude Desktop 的布局。对齐的是它们的完成度，不是它们的界面。
- 用一个转圈代替运行态。那是这个产品最长的一段体验。
- 把审批做成抢走输入焦点的模态；或者反过来，把「一次同意已经变成永久放行」藏起来。
- 把 followup / steer / inject 混成一个「发送」。
- 把 Cordis 教程塞进首次运行。
- 在原生端另存一份「权威」聊天记录（权威在 `session/event` 日志里）。
- 自造一套 RPC 路由。契约是官方 `RpcMethodMap`。
- 把 API key 注入进程环境变量。
- 轮询一个本来就会推给你的流。
- 为了「安全」把 `dsh` 关进 App Sandbox，却让 Agent 没法工作。
- 等上游合并我们的 PR 才发布桌面。
