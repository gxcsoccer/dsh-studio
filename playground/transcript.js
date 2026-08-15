/**
 * 一次真实形状的 agent 回合。四种结构渲染同一份数据，
 * 所以对比的是版式和节奏，不是文案。
 */
const TRANSCRIPT = [
  {
    kind: "user",
    text: "侧栏现在只是个文件夹列表。把它做成工作区书签——会话跟着文件夹走，切回来还在上次那一页。",
  },
  {
    kind: "think",
    ms: 1100,
    title: "读了 3 个文件",
    lines: [
      "会话 id 现在挂在 AppModel 上，切工作区就丢。",
      "WorkspaceStore 已经持久化了 recents，可以复用同一个 bookmark。",
      "官方原则是 model-visible means logged，所以恢复要从 session/event 走，不能在原生端另存一份。",
    ],
  },
  {
    kind: "read",
    ms: 700,
    file: "WorkspaceStore.swift",
    range: "42–61",
    lang: "swift",
    code: [
      "final class WorkspaceStore: ObservableObject {",
      "    @Published var url: URL",
      "    @Published var recents: [URL] = []",
      "",
      "    func open(_ url: URL) {",
      "        self.url = url",
      "        pushRecent(url)",
      "    }",
      "}",
    ],
  },
  {
    kind: "edit",
    ms: 900,
    file: "WorkspaceStore.swift",
    lang: "swift",
    added: 6,
    removed: 1,
    diff: [
      { op: " ", text: "    func open(_ url: URL) {" },
      { op: " ", text: "        self.url = url" },
      { op: "-", text: "        pushRecent(url)" },
      { op: "+", text: "        pushRecent(url)" },
      { op: "+", text: "        bookmarks[url] = lastSessionID" },
      { op: "+", text: "        if let resumed = bookmarks[url] {" },
      { op: "+", text: "            Task { await agents.resume(resumed) }" },
      { op: "+", text: "        }" },
      { op: " ", text: "    }" },
    ],
  },
  {
    kind: "run",
    ms: 1500,
    cmd: "swift build --package-path app",
    out: [
      "Compiling DSH WorkspaceStore.swift",
      "Compiling DSH SidebarSlot.swift",
      "Build complete! (4.21s)",
    ],
    ok: true,
  },
  {
    kind: "approve",
    title: "把工作区书签写进钥匙串？",
    detail: "书签含安全作用域数据。写入 login 钥匙串，不进仓库、不进 profile。",
    accept: "允许一次",
    reject: "这次跳过",
  },
  {
    kind: "say",
    text: "侧栏现在是书签了。切回 dsh-studio 会恢复上一次的会话；恢复走 session/event，原生端不留第二份记录。",
  },
];

const SCENES = {
  session: {
    kicker: "会话 · 进行中",
    title: ["把侧栏做成", "工作区书签"],
    lede: "会话跟着文件夹走。切回来还在上次那一页，恢复从官方事件流重建。",
    phase: "已就绪",
    status: ["已就绪 · 官方运行时", "ok"],
  },
  first: {
    kicker: "第一次打开",
    title: ["先把运行时", "装好"],
    lede: "Studio 是官方 dsh 的原生宿主，不内置 Node。缺什么给一个动作，而不是一篇 Cordis 教程。",
    phase: "缺少依赖",
    status: ["等待依赖 · 未启动", "warn"],
    checks: [
      { state: "ok", title: "Node.js 22.19+", detail: "v22.19.0 · /opt/homebrew/bin/node" },
      { state: "ok", title: "dsh 运行时", detail: "npx @deepseek-ai/dsh · 官方包" },
      { state: "todo", title: "DeepSeek API 密钥", detail: "可以稍后。存钥匙串，不写进仓库。" },
    ],
    actions: [["重新检查", true], ["仍要启动", false]],
  },
  empty: {
    kicker: "工作区",
    title: ["还没有项目", "落在 Studio 里"],
    lede: "打开一个文件夹，会话就跟着它走。用过的会留在侧栏，下次直接回到那一页。",
    phase: "已就绪",
    status: ["已就绪 · 等一个工作区", "ok"],
    actions: [["打开文件夹", true], ["从最近选择", false]],
  },
  error: {
    kicker: "运行时",
    title: ["运行时", "没有起来"],
    lede: "预览版上游会破。可以重启，或修复 studio profile；旧会话日志保持只读。",
    phase: "失败",
    status: ["运行时没有起来", "bad"],
    log: [
      "bridge 127.0.0.1:43180 connection refused",
      "profile studio: bundle dsh-studio not resolved",
      "hint: dsh --profile studio --dump-config",
    ],
    actions: [["重启运行时", true], ["修复 Profile", false]],
  },
};

const SLASH_ITEMS = [
  { title: "新会话", hint: "在这个工作区开一页", tint: "gold" },
  { title: "把 README 交给 Agent", hint: "agent.inject()", tint: "sky" },
  { title: "打开工作区", hint: "⌘O", tint: "mocha" },
  { title: "切换主题", hint: "热更新 token", tint: "coral" },
  { title: "重启运行时", hint: "⇧⌘R", tint: "gold" },
];
