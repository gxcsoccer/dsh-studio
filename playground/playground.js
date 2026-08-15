/**
 * 四个方案渲染同一次会话。参照的是官方 web 客户端的真实表面：
 * 三栏、Chat/Trajectory 双视图、审批接管输入栏、composer 底部一排
 * 访问模式 / 计划 / 模型 / 上下文环、侧栏状态点分优先级。
 */

const VARIANTS = [
  {
    id: "web",
    name: "Web reference",
    zh: "官方 web",
    tag: "参照",
    thesis:
      "官方 dsh web 今天的样子，用它自己的灰阶画的。放在这里是为了量差距——尤其是右边那栏：详情面板在已发布版本里有实现、有文案，但<b>没有入口</b>，点工具行打不开它。",
    edge: "—",
    cost: "—",
    pick: "开对比模式，把它放 B 窗。",
  },
  {
    id: "console",
    name: "Console",
    zh: "控制台",
    tag: "最忠实",
    thesis:
      "同样的三栏，换成 dev-platform 的语言：一个色相、0 圆角、发丝线、等宽当 UI 字体、语法高亮走同色明度阶。桌面在这里补的是官方没接上的那条线——<b>详情面板真的能开</b>，点任意工具行就在右边展开输入 / 输出 / 计时。",
    edge: "接通详情面板；审批可以给持久授权，不只是「允许一次」。",
    cost: "结构最保守。它赢在密度和完成度，不赢在新鲜感。",
    pick: "要一个能对着官方 UI 逐条说清「我们哪里更好」的版本。",
  },
  {
    id: "bench",
    name: "Bench",
    zh: "工作台",
    tag: "偏工程",
    thesis:
      "对话退回窄栏，右边是常驻工作台：当前 diff、终端、读到的文件都在那儿，跟着 agent 走。取的是那页「代码窗 + 焊在底边的终端条」那个部件，把它放大成一整栏。",
    edge: "工具产物有固定位置，不用在流里往回翻。文件页签常驻。",
    cost: "1180 以下要把工作台压成抽屉。窄屏是它的软肋。",
    pick: "主要用途是看着 agent 改代码，而不是聊。",
  },
  {
    id: "ledger",
    name: "Ledger",
    zh: "账本",
    tag: "偏观测",
    thesis:
      "把官方的 Trajectory 视图提成主表面。上面是按真实耗时投影的时间轴，下面是事件账本；带 ● 的是 surface 事件（会进模型上下文的只有 user/message、assistant/message、tool/result 三种）。聊天变成次要页签。",
    edge: "长任务、跑飞了要复盘、要看 TTFT 和工具占比的时候，这是唯一能看的视图。",
    cost: "不适合日常对话。要跟别的方案配着用，不是单独选。",
    pick: "跑长任务、调 agent、排查为什么慢。",
  },
];

const state = { a: "console", b: "web", scene: "session", look: "paper", cmp: false, focus: "a" };
const hosts = { a: document.getElementById("host-a"), b: document.getElementById("host-b") };
const timers = new WeakMap();
const slow = !window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const byId = (id) => VARIANTS.find((v) => v.id === id) || VARIANTS[1];
const wait = (ms) => new Promise((r) => setTimeout(r, slow ? ms : 0));
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
function el(tag, cls, html) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
}

/* ————— 语法：四级明度阶 ————— */

const KW = /\b(func|let|var|if|else|return|struct|final|class|enum|await|async|import|self|guard|try|case|switch|private|public|static|extension|throws|in|for|while|true|false|nil|Task)\b/g;

function hl(line) {
  const out = [];
  let rest = line;
  const re = /(\/\/[^\n]*|"(?:[^"\\]|\\.)*")/;
  let m;
  while ((m = re.exec(rest))) {
    if (m.index > 0) out.push(["o", rest.slice(0, m.index)]);
    out.push([m[0].startsWith("//") ? "c" : "s", m[0]]);
    rest = rest.slice(m.index + m[0].length);
  }
  out.push(["o", rest]);
  return out
    .map(([kind, v]) => {
      const t = esc(v);
      if (kind !== "o") return `<i class="${kind}">${t}</i>`;
      return t
        .replace(KW, '<i class="k">$1</i>')
        .replace(/\b([A-Z][A-Za-z0-9_]+)\b/g, '<i class="f">$1</i>')
        .replace(/\b(\d+(?:\.\d+)?)\b/g, '<i class="n">$1</i>');
    })
    .join("");
}

/* ————— 代码框 ————— */

function readFrame(node, bare) {
  const f = el("div", "codeframe");
  if (!bare) {
    f.append(
      el("div", "cf-bar", `<span class="cf-name">${esc(node.title)}</span><button type="button" class="cf-act">复制</button>`)
    );
  }
  const code = el("pre", "code");
  node.code.forEach((line, i) => {
    code.append(el("div", "ln", `<span class="no">${node.startLine + i}</span><span class="tx">${hl(line)}</span>`));
  });
  f.append(code);
  return f;
}

function diffFrame(node, bare) {
  const f = el("div", "codeframe");
  if (!bare) {
    f.append(
      el("div", "cf-bar", `<span class="cf-name">${esc(node.title)}</span><button type="button" class="cf-act">复制</button>`)
    );
  }
  const code = el("pre", "code");
  node.diff.forEach((row) => {
    const cls = row.op === "+" ? "add" : row.op === "-" ? "del" : "";
    code.append(el("div", `ln dl ${cls}`, `<span class="no">${row.op.trim() || ""}</span><span class="tx">${hl(row.text)}</span>`));
  });
  f.append(code);
  f.append(el("div", "dfoot", `└ ${node.meta}`));
  return f;
}

function termFrame(node, bare) {
  const f = el("div", "codeframe");
  if (!bare) {
    f.append(
      el("div", "cf-bar", `<span class="cf-name">${esc(node.cwd)}</span><span class="tmeta">${esc(node.meta)}</span>`)
    );
  }
  const t = el("pre", "term");
  t.append(el("div", null, `<span class="pr">$ </span>${esc(node.cmd)}`));
  f.append(t);
  return f;
}

function toolFrame(node, bare) {
  if (node.render === "diff") return diffFrame(node, bare);
  if (node.render === "terminal") return termFrame(node, bare);
  return readFrame(node, bare);
}

/** 终端逐行打印，进行中的那行走扫光——不用转圈。 */
async function printTerm(frame, node, alive) {
  const t = frame.querySelector(".term");
  if (!t) return;
  for (const line of node.out) {
    if (!alive()) return;
    const row = el("div", null, `<span class="dim shim">${esc(line)}</span>`);
    t.append(row);
    await wait(340);
    if (!alive()) return;
    row.querySelector("span").classList.remove("shim");
  }
}

/* ————— 侧栏 ————— */

function sidebar(scene) {
  const s = el("aside", "side");
  const top = el("div", "side-top");
  top.append(el("button", "btn btn-primary", "＋ 新会话"), el("button", "btn btn-sm", "⌕"));
  s.append(top);

  WORKSPACES.forEach((ws) => {
    const box = el("div", "ws");
    box.append(
      el("button", "ws-h", `<span class="caret">${ws.open ? "▾" : "▸"}</span><b>${ws.name}</b><em>${ws.sessions.length}</em>`)
    );
    if (!ws.open) return s.append(box);
    const list = el("ul", "ses");
    ws.sessions.forEach((se) => {
      const current = se.state === "current";
      // 审批场景里当前会话变成「等待审批」，琥珀点压过运行中
      const dot = current ? (scene === "approval" ? "wait" : "running") : se.state === "current" ? "running" : se.state;
      const li = el("li", current ? "cur" : "");
      li.innerHTML = `<span class="sdot ${dot}"></span><span class="s-t">${se.title}</span><span class="s-when">${
        current && scene === "approval" ? "待审批" : se.detail || se.when
      }</span>`;
      list.append(li);
    });
    box.append(list);
    s.append(box);
  });

  const foot = el("div", "side-foot");
  foot.innerHTML = `<span>设置</span><span>·</span><span>插件 12</span>`;
  s.append(foot);
  return s;
}

/* ————— 节点流 ————— */

function nodeEl(node, variant) {
  if (node.kind === "user") {
    const n = el("div", "node n-user");
    n.innerHTML = `<div class="n-meta">你 · ${node.time}</div><p>${esc(node.text)}</p>`;
    return n;
  }
  if (node.kind === "assistant") {
    const n = el("div", "node n-asst");
    if (node.reasoning) {
      const d = el("details", "think");
      d.innerHTML = `<summary><span class="think-k">思考</span><span class="think-s">${esc(node.reasoning[0])}</span></summary>`;
      const b = el("div", "think-body");
      node.reasoning.forEach((line) => b.append(el("p", null, esc(line))));
      d.append(b);
      n.append(d);
    }
    if (node.text) n.append(el("p", null, esc(node.text)));
    return n;
  }
  if (node.kind === "turn-tail") {
    const n = el("div", "node tail");
    n.innerHTML =
      `<span>轮 ${node.turn} · ${node.ran}</span><span>TTFT ${node.ttft}</span><span>${node.tps} tok/s</span>` +
      `<span class="files">${node.files.map((f) => `<i class="fpill">${f}</i>`).join("")}</span>`;
    return n;
  }
  if (node.kind === "approval") return null;

  // 工具行。bench 把内容让给工作台，流里只留一行。
  const n = el("div", "node tool run");
  const head = el("button", "tool-h");
  head.innerHTML =
    `<span class="tname">${node.tool}</span><span class="ttitle">${esc(node.title)}</span>` +
    `<span class="tmeta">${esc(node.meta)}</span><span class="tstate"></span>`;
  n.append(head);
  if (variant !== "bench") {
    const body = el("div", "tool-b");
    body.append(toolFrame(node, true));
    n.append(body);
    head.addEventListener("click", () => n.classList.toggle("open"));
  }
  n.dataset.tool = node.tool;
  return n;
}

/* ————— 轨迹 ————— */

const SPAN_TOTAL = 12400;

function trajectory(onSelect) {
  const wrap = el("div", "center");
  const tl = el("div", "tl");
  tl.append(el("div", "tl-h", `<b>概览</b><em>轮 3 · 12.4s · 拖选可筛，滚轮缩放</em>`));
  const track = el("div", "tl-track");
  LEDGER.forEach((row) => {
    const who = row.who === "asst" ? "asst" : row.who === "tool" ? "tool" : row.type.startsWith("approval") ? "wait" : "";
    // span 是 100ms 的倍数，按真实时长投影到时间轴上
    const bar = el("div", `tl-bar ${who}`);
    bar.style.left = `${(row.ms / SPAN_TOTAL) * 100}%`;
    bar.style.width = `${Math.max(((row.span * 100) / SPAN_TOTAL) * 100, 0.8)}%`;
    bar.style.top = `${row.who === "asst" ? 4 : row.who === "tool" ? 14 : 24}px`;
    bar.title = `${row.type} · ${(row.ms / 1000).toFixed(1)}s`;
    track.append(bar);
  });
  tl.append(track);
  tl.append(el("div", "tl-ticks", `<span>0s</span><span>3s</span><span>6s</span><span>9s</span><span>12s</span>`));
  wrap.append(tl);

  const scroll = el("div", "flow");
  scroll.style.padding = "0";
  const table = el("table", "led");
  table.innerHTML = `<thead><tr><th>#</th><th>事件</th><th>内容</th><th style="text-align:right">耗时</th></tr></thead>`;
  const tb = el("tbody");
  LEDGER.forEach((row, i) => {
    const tr = el("tr", i === 8 ? "sel" : "");
    tr.innerHTML =
      `<td class="lq">${row.seq}</td>` +
      `<td class="lt">${row.type}${row.surface ? '<span class="surf" title="surface 事件"></span>' : ""}</td>` +
      `<td class="lc">${esc(row.text)}</td>` +
      `<td class="lm">${(row.ms / 1000).toFixed(1)}s</td>`;
    tr.addEventListener("click", () => {
      tb.querySelectorAll("tr").forEach((n) => n.classList.remove("sel"));
      tr.classList.add("sel");
      onSelect?.(row);
    });
    tb.append(tr);
  });
  table.append(tb);
  scroll.append(table);
  wrap.append(scroll);
  return wrap;
}

/* ————— 右栏 ————— */

function detailsRail(variant, scene) {
  const r = el("aside", "rail");
  r.append(el("div", "rail-h", `<b>详情</b><em>${variant === "web" ? "无入口" : "read · 42–61"}</em>`));

  if (variant === "web") {
    const e = el("div", "empty");
    e.innerHTML =
      `<p>点消息流里的工具行查看详情。</p>` +
      `<p class="deadnote">openDetails 已实现但无人调用<br />这一栏在发布版里打不开</p>`;
    r.append(e);
    return r;
  }

  const s1 = el("div", "sect");
  s1.append(el("h4", null, "输入"));
  s1.append(
    el(
      "dl",
      "kv",
      `<dt>tool</dt><dd class="mono">read</dd>` +
        `<dt>path</dt><dd class="mono">app/…/WorkspaceStore.swift</dd>` +
        `<dt>range</dt><dd class="mono">42–61</dd>`
    )
  );
  r.append(s1);

  const s2 = el("div", "sect");
  s2.append(el("h4", null, "输出"));
  const f = readFrame(NODES[2], true);
  f.querySelector(".code").style.maxHeight = "168px";
  s2.append(f);
  r.append(s2);

  const s3 = el("div", "sect");
  s3.append(el("h4", null, "计时"));
  s3.append(
    el("dl", "kv", `<dt>排队</dt><dd class="mono">12ms</dd><dt>执行</dt><dd class="mono">688ms</dd><dt>token</dt><dd class="mono">1,204</dd>`)
  );
  r.append(s3);

  const s4 = el("div", "sect");
  s4.append(el("h4", null, "会话"));
  s4.append(
    el(
      "dl",
      "kv",
      `<dt>模式</dt><dd>${SESSION.preset}</dd>` +
        `<dt>访问</dt><dd>${scene === "approval" ? "workspace-write" : SESSION.accessLabel}</dd>` +
        `<dt>profile</dt><dd class="mono">studio</dd>` +
        `<dt>桥</dt><dd class="mono">127.0.0.1:43180</dd>`
    )
  );
  r.append(s4);
  return r;
}

function benchRail(scene) {
  const b = el("aside", "bench");
  const edit = NODES[3];
  const term = NODES[4];
  b.append(el("div", "bench-h", `<span class="tname">edit</span><b>${edit.title}</b><span class="tmeta">${edit.meta}</span>`));
  b.append(el("div", "bench-tabs", `<button class="on">WorkspaceStore.swift</button><button>SidebarSlot.swift</button><button>终端</button>`));
  const body = el("div", "bench-b");
  body.append(diffFrame(edit, true));
  b.append(body);
  const bot = el("div", "bench-t");
  bot.append(termFrame(term, false));
  const t = bot.querySelector(".term");
  term.out.forEach((line) => t.append(el("div", null, `<span class="dim">${esc(line)}</span>`)));
  b.append(bot);
  return b;
}

function ledgerRail() {
  const r = el("aside", "rail");
  r.append(el("div", "rail-h", `<b>记录</b><em>#132</em>`));
  const s1 = el("div", "sect");
  s1.append(el("h4", null, "tool/call"));
  s1.append(el("dl", "kv", `<dt>tool</dt><dd class="mono">bash</dd><dt>轮/步</dt><dd class="mono">3 / 2</dd><dt>surface</dt><dd class="mono">否</dd>`));
  r.append(s1);
  const s2 = el("div", "sect");
  s2.append(el("h4", null, "输入"));
  s2.append(el("pre", "code", `<div class="ln"><span class="tx">${hl('"swift build --package-path app"')}</span></div>`));
  r.append(s2);
  const s3 = el("div", "sect");
  s3.append(el("h4", null, "计时"));
  s3.append(el("dl", "kv", `<dt>开始</dt><dd class="mono">5.40s</dd><dt>时长</dt><dd class="mono">4.21s</dd><dt>等审批</dt><dd class="mono">2.40s</dd>`));
  r.append(s3);
  const s4 = el("div", "sect");
  s4.append(el("h4", null, "本轮统计"));
  s4.append(
    el("dl", "kv", `<dt>轮 · 步</dt><dd class="mono">3 · 7</dd><dt>LLM</dt><dd class="mono">${SESSION.stats.llm}</dd><dt>工具</dt><dd class="mono">${SESSION.stats.tools}</dd><dt>缓存命中</dt><dd class="mono">${SESSION.stats.cache}%</dd>`)
  );
  r.append(s4);
  return r;
}

/* ————— composer ————— */

function composerStack(variant, scene) {
  const dock = el("div", "dock");

  const st = SESSION.stats;
  dock.append(
    el(
      "div",
      "strip",
      `<span>${st.turns} 轮 · ${st.steps} 步</span><span class="sep">·</span><span>LLM ${st.llm}</span>` +
        `<span class="sep">·</span><span>工具 ${st.tools}</span><span class="sep">·</span><span>首 token ${st.ttft}</span>` +
        `<span class="sep">·</span><span>${st.tps} tok/s</span><span class="sep">·</span><span>缓存 ${st.cache}%</span>`
    )
  );

  const todos = el("div", "todos");
  todos.append(el("span", "tk", "任务"));
  TODOS.forEach((t) => {
    todos.append(el("span", `todo ${t.done ? "done" : ""} ${t.active ? "now" : ""}`, `<b></b>${t.text}`));
  });
  dock.append(todos);

  const wrap = el("div", "cwrap");

  if (scene === "approval") {
    const ap = NODES.find((n) => n.kind === "approval");
    const panel = el("div", "approve");
    panel.innerHTML =
      `<div class="ap-top"><span class="ap-k">等待审批</span><span class="ap-r">${esc(ap.reason)}</span></div>` +
      `<div class="ap-cmd">${esc(ap.command)}</div>` +
      `<div class="ap-note">${esc(ap.note)}</div>`;
    const btns = el("div", "ap-btns");
    btns.append(el("button", "btn btn-primary", "允许一次"), el("button", "btn", "拒绝"));
    if (variant !== "web") {
      // 官方 web 只有 allow-once / reject，没有持久授权。桌面补这一格。
      const grant = el("label", "ap-grant");
      grant.innerHTML = `<input type="checkbox" />本会话内记住 bash`;
      btns.append(grant);
    }
    panel.append(btns);
    wrap.append(panel);
    dock.append(wrap);
    return dock;
  }

  const c = el("div", "composer");
  c.innerHTML =
    `<div class="crow1"><button type="button" class="plus">+</button>` +
    `<textarea rows="1" placeholder="给智能体写点什么，或按 / 唤起命令" aria-label="输入"></textarea></div>`;
  const row2 = el("div", "crow2");
  const pct = Math.round((SESSION.context.used / SESSION.context.capacity) * 100);
  // 上下文环和发送键钉住右边；窄栏时先裁左边的 chip，不能裁发送。
  row2.innerHTML =
    `<span class="cchips">` +
    `<button type="button" class="chip">访问 · ${SESSION.accessLabel}</button>` +
    `<button type="button" class="chip">计划 · 关</button>` +
    `<button type="button" class="chip">${SESSION.model} · ${SESSION.effort}</button>` +
    `</span>` +
    `<span class="ringwrap"><span class="ring" style="background:conic-gradient(var(--field) 0 ${pct}%, var(--line) ${pct}% 100%)"></span>${pct}%</span>` +
    `<button type="button" class="send">↑</button>`;
  c.append(row2);
  wrap.append(c);
  wrap.append(el("div", "slash"));
  dock.append(wrap);
  return dock;
}

/* ————— 组装 ————— */

function buildApp(variant, scene, look) {
  const app = el("div", "app");
  app.dataset.v = variant;
  app.dataset.scene = scene;

  const tbar = el("header", "tbar");
  tbar.innerHTML = `<div class="lights"><i></i><i></i><i></i></div><span class="wm">dsh-studio</span>`;
  const mid = el("div", "tbar-mid");
  mid.append(el("span", "tbar-path", SESSION.path));
  tbar.append(mid);
  const tr = el("div", "tbar-right");
  tr.append(el("button", "btn btn-sm", "工作区"), el("button", "btn btn-sm btn-primary", "＋"));
  tbar.append(tr);
  app.append(tbar);

  const body = el("div", "body3");
  body.append(sidebar(scene));

  const wantsTrajectory = scene === "trajectory" || variant === "ledger";

  if (scene === "hero") {
    const center = el("div", "center");
    const hero = el("div", "hero");
    hero.innerHTML =
      `<span class="hero-badge">Preview</span>` +
      `<h2>探索未至之境</h2>` +
      `<p class="lede">选一个工作区就能开始。会话跟着文件夹走。</p>`;
    const pick = el("button", "hero-pick", `<b>选择工作区</b><span>原生对话框 · 最近用过 4 个</span>`);
    hero.append(pick);
    center.append(hero);
    center.append(composerStack(variant, scene));
    body.append(center);
  } else if (wantsTrajectory) {
    const center = trajectory();
    const head = el("div", "chead");
    head.innerHTML = `<h1>${SESSION.title}</h1>`;
    const tabs = el("div", "vtabs");
    tabs.innerHTML = `<button>Chat</button><button class="on">Trajectory</button>`;
    head.append(tabs);
    center.prepend(head);
    center.append(composerStack(variant, scene));
    body.append(center);
  } else {
    const center = el("div", "center");
    const head = el("div", "chead");
    head.innerHTML = `<h1>${SESSION.title}</h1>`;
    const tabs = el("div", "vtabs");
    tabs.innerHTML = `<button class="on">Chat</button><button>Trajectory</button>`;
    head.append(tabs, el("button", "btn btn-sm", "子智能体 2"), el("button", "btn btn-sm", "作业"));
    center.append(head);
    center.append(el("div", "flow"));
    center.append(composerStack(variant, scene));
    body.append(center);
  }

  if (variant === "bench") body.append(benchRail(scene));
  else if (variant === "ledger") body.append(ledgerRail());
  else body.append(detailsRail(variant, scene));

  app.append(body);

  const sc = SCENES[scene];
  const sbar = el("footer", "sbar");
  sbar.innerHTML =
    `<span class="dot ${sc.tone === "wait" ? "wait" : ""}"></span><span>${sc.status}</span>` +
    `<span class="right"><span>${SESSION.preset}</span><span>3080 · 43180</span></span>`;
  app.append(sbar);
  return app;
}

/* ————— 播放 ————— */

async function play(app) {
  const token = {};
  timers.set(app, token);
  const alive = () => timers.get(app) === token && app.isConnected;
  const flow = app.querySelector(".flow");
  if (!flow || app.dataset.scene === "hero") return;
  if (app.querySelector(".led")) return;
  flow.replaceChildren();

  const variant = app.dataset.v;
  const stopAt = app.dataset.scene === "approval" ? NODES.findIndex((n) => n.kind === "approval") : NODES.length;

  for (let i = 0; i < stopAt; i += 1) {
    if (!alive()) return;
    const node = NODES[i];
    const n = nodeEl(node, variant);
    if (!n) continue;
    n.classList.add("enter");
    flow.append(n);
    flow.scrollTop = flow.scrollHeight;

    if (node.kind === "tool") {
      await wait(node.ms);
      if (!alive()) return;
      if (node.render === "terminal" && variant !== "bench") {
        n.classList.add("open");
        await printTerm(n.querySelector(".tool-b"), node, alive);
      }
      n.classList.remove("run");
      n.classList.add("ok");
      if (variant !== "bench" && node.render === "diff") n.classList.add("open");
    } else {
      await wait(360);
    }
    flow.scrollTop = flow.scrollHeight;
  }

  // 审批场景：最后那次 bash 停在运行中，输入栏已经被审批面板接管
  if (app.dataset.scene === "approval") {
    const last = flow.querySelector(".tool:last-of-type");
    if (last) {
      last.classList.remove("ok");
      last.classList.add("run");
    }
  }
}

/* ————— / 菜单锚在光标 ————— */

function caretXY(ta) {
  const wrap = ta.closest(".cwrap");
  const cs = getComputedStyle(ta);
  const m = el("div", "mirror");
  ["fontSize", "fontFamily", "fontWeight", "lineHeight", "letterSpacing", "padding", "width"].forEach((p) => {
    m.style[p] = cs[p];
  });
  const box = ta.getBoundingClientRect();
  const ref = wrap.getBoundingClientRect();
  m.style.left = `${box.left - ref.left}px`;
  m.style.top = `${box.top - ref.top}px`;
  m.textContent = ta.value.slice(0, ta.selectionStart);
  const mark = el("span", null, "\u200b");
  m.append(mark);
  wrap.append(m);
  const pt = { x: mark.offsetLeft, y: mark.offsetTop };
  m.remove();
  return pt;
}

function openSlash(app, atCaret) {
  const menu = app.querySelector(".slash");
  const ta = app.querySelector("textarea");
  if (!menu || !ta) return;
  menu.replaceChildren();
  SLASH.forEach((item, i) => {
    const b = el("button", i === 0 ? "on" : "");
    b.innerHTML = `<span class="sn">${item.name}</span><span class="sh">${item.hint}</span><span class="sd">${item.desc}</span>`;
    b.addEventListener("click", () => {
      ta.value = `${item.name} `;
      menu.classList.remove("open");
      ta.focus();
    });
    menu.append(b);
  });
  const wrap = app.querySelector(".cwrap");
  if (atCaret) {
    const p = caretXY(ta);
    menu.style.left = `${Math.min(p.x, wrap.clientWidth - 332)}px`;
    menu.style.bottom = `${wrap.clientHeight - p.y + 4}px`;
  } else {
    menu.style.left = "14px";
    menu.style.bottom = `${wrap.clientHeight - 4}px`;
  }
  menu.classList.add("open");
}

function bind(app) {
  const ta = app.querySelector("textarea");
  if (!ta) return;
  ta.addEventListener("input", () => {
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 96)}px`;
    if (ta.value.endsWith("/")) openSlash(app, true);
    else if (!ta.value.startsWith("/")) app.querySelector(".slash")?.classList.remove("open");
  });
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Escape") app.querySelector(".slash")?.classList.remove("open");
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit(app);
    }
  });
  app.querySelector(".send")?.addEventListener("click", () => submit(app));
  app.querySelector(".plus")?.addEventListener("click", () => {
    ta.focus();
    openSlash(app, false);
  });
}

function submit(app) {
  const ta = app.querySelector("textarea");
  const text = ta.value.trim();
  app.querySelector(".slash")?.classList.remove("open");
  if (!text) return;
  const flow = app.querySelector(".flow");
  if (flow && !app.querySelector(".led")) {
    const n = el("div", "node n-user enter");
    n.innerHTML = `<div class="n-meta">你 · 排队</div><p></p>`;
    n.querySelector("p").textContent = text;
    flow.append(n);
    flow.scrollTop = flow.scrollHeight;
  }
  ta.value = "";
  ta.style.height = "auto";
}

/* ————— 外壳 ————— */

function mount(which) {
  const app = buildApp(state[which], state.scene, state.look);
  hosts[which].replaceChildren(app);
  bind(app);
  play(app);
  const cap = document.querySelector(`[data-win="${which}"] figcaption b`);
  if (cap) cap.textContent = byId(state[which]).zh;
}

function mountAll() {
  mount("a");
  if (state.cmp) mount("b");
}

function renderCards() {
  const side = document.querySelector(".pg-side");
  side.querySelectorAll(".vcard").forEach((n) => n.remove());
  VARIANTS.forEach((v, i) => {
    const c = el("button", "vcard");
    c.dataset.v = v.id;
    c.innerHTML = `<span class="vk"><b>${v.zh}</b><em>${i + 1}</em></span><p>${v.tag} · ${v.name}</p>`;
    c.addEventListener("click", () => pick(v.id));
    side.append(c);
  });
  syncCards();
}

function syncCards() {
  const cur = state[state.focus];
  document.querySelectorAll(".vcard").forEach((c) => c.classList.toggle("on", c.dataset.v === cur));
}

function renderNotes() {
  const v = byId(state[state.focus]);
  document.querySelector(".pg-notes").innerHTML =
    `<p class="eyebrow">${v.tag}</p><h3>${v.zh}</h3><p class="sub">${v.name}</p>` +
    `<p>${v.thesis}</p><dl>` +
    `<dt>比官方 web 多了什么</dt><dd>${v.edge}</dd>` +
    `<dt>代价</dt><dd>${v.cost}</dd>` +
    `<dt>什么时候选它</dt><dd>${v.pick}</dd></dl>`;
}

function pick(id) {
  state[state.focus] = id;
  mount(state.focus);
  syncCards();
  renderNotes();
  hash();
}

function setScene(scene) {
  state.scene = scene;
  document.querySelectorAll("[data-scene]").forEach((b) => b.classList.toggle("on", b.dataset.scene === scene));
  mountAll();
  hash();
}

function setLook(look) {
  state.look = look;
  document.body.dataset.look = look;
  document.querySelectorAll("[data-look]").forEach((b) => {
    if (b.tagName === "BUTTON") b.classList.toggle("on", b.dataset.look === look);
  });
  hash();
}

function toggleCmp() {
  state.cmp = !state.cmp;
  if (!state.cmp) {
    state.focus = "a";
    document.querySelectorAll(".frame").forEach((f) => f.classList.toggle("on", f.dataset.win === "a"));
  }
  document.querySelector('[data-act="cmp"]').setAttribute("aria-pressed", String(state.cmp));
  document.querySelector(".pg-stage").dataset.cmp = String(state.cmp);
  document.querySelector('[data-win="b"]').hidden = !state.cmp;
  if (state.cmp) mount("b");
  syncCards();
  renderNotes();
  hash();
}

function hash() {
  const p = new URLSearchParams({ v: state.a, scene: state.scene, look: state.look });
  if (state.cmp) {
    p.set("cmp", "1");
    p.set("b", state.b);
  }
  history.replaceState(null, "", `#${p}`);
}

function readHash() {
  const p = new URLSearchParams(location.hash.slice(1));
  const ids = VARIANTS.map((v) => v.id);
  if (ids.includes(p.get("v"))) state.a = p.get("v");
  if (ids.includes(p.get("b"))) state.b = p.get("b");
  if (SCENES[p.get("scene")]) state.scene = p.get("scene");
  if (["paper", "field"].includes(p.get("look"))) state.look = p.get("look");
  if (p.get("cmp") === "1") state.cmp = true;
}

document.querySelectorAll(".tabs2 [data-scene]").forEach((b) => b.addEventListener("click", () => setScene(b.dataset.scene)));
document.querySelectorAll(".seg [data-look]").forEach((b) => b.addEventListener("click", () => setLook(b.dataset.look)));
document.querySelector('[data-act="cmp"]').addEventListener("click", toggleCmp);
document.querySelector('[data-act="replay"]').addEventListener("click", () => mountAll());
document.querySelectorAll(".frame").forEach((f) =>
  f.addEventListener("mousedown", () => {
    if (!state.cmp) return;
    state.focus = f.dataset.win;
    document.querySelectorAll(".frame").forEach((n) => n.classList.toggle("on", n === f));
    syncCards();
    renderNotes();
  })
);

document.getElementById("accs").innerHTML = VARIANTS.map(
  (v, i) => `<span class="acc">[<i>${i + 1}</i>]${v.zh}</span>`
).join(" ");

window.addEventListener("keydown", (e) => {
  if (["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName)) {
    if (e.key === "Escape") document.querySelectorAll(".slash").forEach((m) => m.classList.remove("open"));
    return;
  }
  const n = Number(e.key);
  if (n >= 1 && n <= VARIANTS.length) pick(VARIANTS[n - 1].id);
  const k = e.key.toLowerCase();
  const scenes = { q: "session", w: "approval", e: "trajectory", r: "hero" };
  if (scenes[k]) setScene(scenes[k]);
  if (k === "c") toggleCmp();
  if (k === "d") setLook(state.look === "paper" ? "field" : "paper");
  if (e.code === "Space") {
    e.preventDefault();
    mountAll();
  }
  if (e.key === "/") {
    e.preventDefault();
    const app = hosts[state.cmp ? state.focus : "a"].querySelector(".app");
    const ta = app?.querySelector("textarea");
    if (ta) {
      ta.focus();
      openSlash(app, false);
    }
  }
});

readHash();
setLook(state.look);
document.querySelectorAll("[data-scene]").forEach((b) => b.classList.toggle("on", b.dataset.scene === state.scene));
document.querySelector('[data-act="cmp"]').setAttribute("aria-pressed", String(state.cmp));
document.querySelector(".pg-stage").dataset.cmp = String(state.cmp);
document.querySelector('[data-win="b"]').hidden = !state.cmp;
renderCards();
mountAll();
renderNotes();
hash();
