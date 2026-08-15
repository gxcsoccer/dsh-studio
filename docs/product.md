# Product bar

DSH Studio 要对齐的是 Linear / Raycast 这一档桌面，而不是「能把官方网页打开」这一档壳。
The bar is a native product, not a successful iframe.

这份笔记写的是 *产品标准*。`app/` 已按这些标准落地第一版 SwiftUI 宿主：首次运行检查、空状态、命令面板、钥匙串、工作区书签、主题热更新。Linux 上不要指望编出 .app。

---

## 世界级意味着什么 / What “world-class” means here

- **Chrome 是我们的。** 标题栏、侧栏、命令面板、通知、文件选择，都按桌面习惯长，而不是浏览器里那一套再套个交通灯。
- **会话是第一场景。** 打开应用就能回到工作区和上一次会话。恢复 / 分叉 / 检索是产品功能，不是「你自己去 Harness home 翻」。
- **插件是可见的。** 「一切皆插件」不能只写在开发者文档里。用户要能看见已装的 bundle、关掉有问题的一层、在失败时得到人话。
- **键盘是完整的。** 命令面板、会话列表、发送 / 取消 / 切工作区都有快捷键，并且可发现。
- **安静。** 默认不吵。Agent 跑完可以通知；打字时不要抢焦点、不要弹模态。

做不到上面这些，就还是又一个 wrapper。社区里已经有三个了。

---

## 首次运行 / First-run

第一次打开 **不能** 假设用户读过 Cordis primer，也不能把 `cordis.patch.yml` 摊在脸上。

合格的首次运行：

1. **检查环境，用人话讲结果。** Node 在不在、官方 `dsh` 能不能用、工作目录写不写得了。缺什么，给一个动作（安装 Node、安装 `dsh`、打开官方文档），而不是一段 Cordis 栈。
2. **创建 `studio` profile，而不是让用户自己叠 bundle。** 第一层是 `@deepseek-ai/dsh-base`，第二层是我们的 bundle。用户此时不需要知道这两个名字。
3. **密钥进钥匙串，不进明文文件、不进仓库。** 提示来自系统钥匙串 / 凭据柜，而不是「请 export 一个环境变量然后重启终端」。
4. **选一个工作区就开得了会话。** 原生文件对话框。不要先丢用户去官方 Web UI 里找目录选择器。
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
| `dsh` 不在 | 官方运行时还没装好 | 指向官方安装，保留重试 |
| 会话被上游格式弄破 | preview 破了兼容 | 说明、只读旧日志、开新会话；不要假装能修 |

空状态的文案用产品语言（工作区、会话、插件、密钥），不用实现语言（fiber、row id、waterfall、`SessionEventMap`）。

---

## 无障碍 / Accessibility

v1 就要当一等需求，而不是「以后补 aria」。

- macOS VoiceOver：会话列表、消息流、命令面板、插件开关都可以聚焦、都有标签。
- 完整键盘路径：不依赖指针也能完成首次运行、发一条消息、取消一轮、切工作区。
- 对比度和动态字体跟系统走。
- `Reduce Motion`：关掉非必要过渡；流式输出仍然可读，只是不「飞」。
- 通知可关，并尊重系统勿扰。
- 色不只是信息：错误 / 运行中 / 完成有文字或图标，不单靠红绿。

SwiftUI 宿主应优先用系统控件和 Accessibility API。日后 Tauri 宿主必须对等，不能「Mac 能读、Win/Linux 只能看」。

---

## 签名与分发 / Signing (later)

v1 可以是未签名的开发构建（本地 `swift build` / Xcode Run）。**签名、公证、更新通道是产品的一部分，但不是第一个里程碑。**

之后按这个顺序，而不是一上来就折腾分发：

1. 开发者自己能跑 `studio` profile 和原生窗。
2. Developer ID 签名 + notarization（Mac）；Win / Linux 的等价物跟 Tauri 宿主一起做。
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
- 我们自己的约束仍然在：桥只绑 `127.0.0.1`；密钥进钥匙串；不把工作区复制进容器「假装安全」。
- 官方 harness 自己的 sandbox / 审批策略继续管 *Agent 能碰什么*。那是 `dsh-base` 的职责，不是用 App Sandbox 再包一层假安全感。

如果未来要上 Mac App Store，那是另一条产品线（能力会更窄），不是把 v1 塞进沙箱。

---

## 明确不做 / Not in the product

- 再做一个官方 Web UI 的皮肤。
- 把 Cordis 教程塞进首次运行。
- 在原生端另存一份「权威」聊天记录（权威在 `session/event` 日志里）。
- 为了「安全」把 `dsh` 关进 App Sandbox，却让 Agent 没法工作。
- 等上游合并我们的 PR 才发布桌面。
