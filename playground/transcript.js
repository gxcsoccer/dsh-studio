/**
 * 按 DeepSeek Harness 官方 web 客户端的真实模型建的数据。
 *
 * 会话 = 若干轮，轮 = 若干步。聊天视图渲染的是 Conversation Node，
 * 不是原始事件；assistant 消息由 text / reasoning / tool-call 块组成。
 * 上下文占用、统计、待办、权限这些数字都是宿主算好的投影，客户端不自己折叠。
 * 词汇跟着官方 UI：会话、工作区、轮、步、工具、访问模式、审批、任务。
 */

const SESSION = {
  title: "把侧栏做成工作区书签",
  workspace: "dsh-studio",
  path: "~/projj/github.com/gxcsoccer/dsh-studio",
  preset: "Standard mode",
  access: "workspace-write",
  accessLabel: "Workspace write",
  model: "deepseek-v4-pro",
  effort: "high",
  context: { used: 41200, capacity: 128000 },
  stats: {
    turns: 3,
    steps: 7,
    llm: "18.4s",
    tools: "6.1s",
    ttft: "0.9s",
    tps: 62,
    cache: 78,
    input: 41200,
    output: 3840,
  },
};

const WORKSPACES = [
  {
    name: "dsh-studio",
    path: "~/projj/github.com/gxcsoccer/dsh-studio",
    open: true,
    sessions: [
      { title: "把侧栏做成工作区书签", when: "刚刚", state: "current" },
      { title: "主题 token 热更新", when: "2 小时前", state: "running", detail: "运行中" },
      { title: "首次运行的检查文案", when: "昨天", state: "done", detail: "未查看" },
      { title: "桥接端口冲突排查", when: "昨天", state: "idle" },
    ],
  },
  {
    name: "harness-docs",
    path: "~/projj/github.com/deepseek-ai/deepseek-harness",
    open: false,
    sessions: [
      { title: "读 session/event 目录", when: "3 天前", state: "wait", detail: "等待审批" },
    ],
  },
];

const TODOS = [
  { text: "侧栏改成按工作区分组", done: true },
  { text: "书签写进钥匙串", done: false, active: true },
  { text: "切回工作区时恢复会话", done: false },
];

/** 一轮的节点流。tool 的 render 字段对应官方的渲染意图。 */
const NODES = [
  {
    kind: "user",
    time: "14:02",
    text: "侧栏现在只是文件夹列表。做成工作区书签——会话跟着文件夹走，切回来还在上次那一页。",
  },
  {
    kind: "assistant",
    turn: 3,
    step: 1,
    reasoning: [
      "会话 id 挂在 AppModel 上，切工作区就丢。",
      "WorkspaceStore 已经持久化了 recents，可以复用同一条书签。",
      "恢复要从 session/event 重建，原生端不另存一份权威记录。",
    ],
    text: "先看现在工作区是怎么存的。",
  },
  {
    kind: "tool",
    tool: "read",
    render: "read",
    ms: 700,
    title: "WorkspaceStore.swift",
    meta: "42–61 行，共 118 行",
    lang: "swift",
    startLine: 42,
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
    kind: "tool",
    tool: "edit",
    render: "diff",
    ms: 900,
    title: "WorkspaceStore.swift",
    meta: "+6 −1 · 1 个文件",
    lang: "swift",
    diff: [
      { op: " ", text: "    func open(_ url: URL) {" },
      { op: " ", text: "        self.url = url" },
      { op: "-", text: "        pushRecent(url)" },
      { op: "+", text: "        pushRecent(url)" },
      { op: "+", text: "        bookmarks[url] = lastSessionID" },
      { op: "+", text: "" },
      { op: "+", text: "        if let resumed = bookmarks[url] {" },
      { op: "+", text: "            Task { await agents.resume(resumed) }" },
      { op: "+", text: "        }" },
      { op: " ", text: "    }" },
    ],
  },
  {
    kind: "tool",
    tool: "bash",
    render: "terminal",
    ms: 1600,
    title: "swift build --package-path app",
    meta: "退出 0",
    cwd: "~/…/dsh-studio",
    cmd: "swift build --package-path app",
    out: [
      "Compiling DSH WorkspaceStore.swift",
      "Compiling DSH SidebarSlot.swift",
      "Build complete! (4.21s)",
    ],
    ok: true,
  },
  {
    kind: "approval",
    tool: "bash",
    reason: "工具 bash 请求越权执行",
    command: "security add-generic-password -s dsh-studio -a bookmarks -w",
    note: "写入 login 钥匙串。工作区书签含安全作用域数据，不进仓库、不进 profile。",
  },
  {
    kind: "assistant",
    turn: 3,
    step: 2,
    text: "侧栏现在是书签了。切回 dsh-studio 会恢复上一次的会话，恢复走 session/event，原生端不留第二份记录。",
  },
  {
    kind: "turn-tail",
    turn: 3,
    ran: "24.5s",
    ttft: "0.9s",
    tps: 62,
    files: ["WorkspaceStore.swift", "SidebarSlot.swift"],
  },
];

/** Trajectory 视图的事件账本。官方那栏只有序号、事件、内容三列。 */
const LEDGER = [
  { seq: 118, type: "turn/start", who: "", text: "turn 3", ms: 0, span: 2 },
  { seq: 119, type: "user/message", who: "user", text: "侧栏现在只是文件夹列表。做成工作区书签…", ms: 0, span: 3 },
  { seq: 120, type: "step/start", who: "", text: "step 1", ms: 120, span: 2 },
  { seq: 121, type: "assistant/chunk", who: "asst", text: "reasoning · 3 段", ms: 900, span: 26, ttft: 9 },
  { seq: 124, type: "tool/call", who: "tool", text: "read WorkspaceStore.swift", ms: 3100, span: 8 },
  { seq: 125, type: "tool/result", who: "tool", text: "20 行", ms: 3800, span: 3, surface: true },
  { seq: 128, type: "tool/call", who: "tool", text: "edit WorkspaceStore.swift", ms: 4200, span: 10 },
  { seq: 129, type: "tool/result", who: "tool", text: "+6 −1", ms: 5100, span: 3, surface: true },
  { seq: 132, type: "tool/call", who: "tool", text: "bash swift build", ms: 5400, span: 18 },
  { seq: 133, type: "approval/asked", who: "", text: "bash · 越权", ms: 7000, span: 4 },
  { seq: 134, type: "approval/decided", who: "", text: "allowed-once", ms: 9400, span: 2 },
  { seq: 136, type: "tool/result", who: "tool", text: "退出 0", ms: 9600, span: 3, surface: true },
  { seq: 140, type: "assistant/message", who: "asst", text: "侧栏现在是书签了…", ms: 10200, span: 12, surface: true },
  { seq: 142, type: "step/end", who: "", text: "step 2", ms: 11800, span: 2 },
  { seq: 143, type: "turn/end", who: "", text: "turn 3 · 24.5s", ms: 12000, span: 2 },
];

/** `/` 触发器的候选。命令来自宿主，技能来自 dsh-tool-skill。 */
const SLASH = [
  { name: "/plan", hint: "[off|message]", desc: "进入或离开计划模式", src: "命令" },
  { name: "/compact", hint: "", desc: "压缩较早的对话历史", src: "命令" },
  { name: "/permission", hint: "<preset>", desc: "切换访问模式", src: "命令" },
  { name: "/goal", hint: "[<目标>|clear]", desc: "为长任务设定目标", src: "命令" },
  { name: "/model", hint: "", desc: "切换模型与思考强度", src: "命令" },
  { name: "/export", hint: "", desc: "把会话日志导出为 ZIP", src: "命令" },
  { name: "/review-diff", hint: "", desc: "逐文件过一遍改动", src: "技能" },
];

const SCENES = {
  session: { label: "会话", tone: "ok", status: "已就绪 · 官方运行时" },
  approval: { label: "审批", tone: "wait", status: "等待审批 · bash 越权" },
  hero: { label: "新会话", tone: "ok", status: "已就绪 · 未选择工作区" },
  trajectory: { label: "轨迹", tone: "ok", status: "已就绪 · 官方运行时" },
};
