/**
 * 两个轴：皮肤（视觉语言）× 结构（三栏怎么排）。
 * 表面按官方 dsh web 客户端建：三栏、Chat/Trajectory、审批接管输入栏、
 * composer 底部访问模式/计划/模型/上下文环、侧栏状态点分优先级。
 */

const SKINS = [
  {
    id: "blueprint",
    zh: "蓝图",
    en: "Blueprint",
    sw: ["#fff", "#1313ba", "#cbcbef"],
    blurb: "一个色相、0 圆角、等宽当 UI 字",
    thesis:
      "notion.com/product/dev 那套 campaign theme 的直译：一个色相十个值，正文是品牌蓝 66% 透明而不是灰；圆角全 0，只有代码框留 4px；阴影归零，全窗只有一种线色；语法高亮是同色四级明度阶。",
    fit: "Agent 要同时摆 prose、diff、终端三种东西。<b>同一个色相做完全部层级</b>，代码块就不会像贴进来的第三方组件。",
    risk: "蓝铺满会有点冷，长时间看偏硬。暗色是把蓝场翻过来，不是灰黑。",
  },
  {
    id: "graphite",
    zh: "石墨",
    en: "Graphite",
    sw: ["#fff", "#000", "#ebebeb"],
    blurb: "无彩、极端克制、纯黑暗色",
    thesis:
      "一个口音都不给。层级只靠字重、字距和 1px 线，颜色只在状态上出现。暗色是真 #000，不是深灰。小圆角 5–8px，克制但不冷。",
    fit: "Agent 界面本来就吵——工具在跑、状态在变、diff 有红绿。<b>底子彻底无彩，状态色才有地方响。</b>",
    risk: "截图不出彩，评审会上最吃亏。它的好要用久了才认。",
  },
  {
    id: "vellum",
    zh: "犊皮",
    en: "Vellum",
    sw: ["#fbfaf7", "#24408e", "#cdc7b8"],
    blurb: "衬线正文、线不成框、编辑性",
    thesis:
      "把会话当印出来的文稿：暖白纸、衬线正文 16px/27px、卡片退成规则线（工具行只有一条上边），代码窗不围框、只留一条左规则。深墨蓝做唯一动作色。",
    fit: "Agent 会话<b>本身就是文档</b>——要读、要引用、要归档。这套让它读起来像一份东西，而不是一条聊天记录。",
    risk: "密度最低，同屏能放的最少。真要跑长任务时信息量吃紧。",
  },
  {
    id: "instrument",
    zh: "仪器",
    en: "Instrument",
    sw: ["#e9e8e4", "#16161a", "#ff5c00"],
    blurb: "机加工面板、字冠标签、一个热口音",
    thesis:
      "Braun / TE 那一路：2px 机加工圆角、9px 全大写 0.13em 字距的标签、所有数字等宽且表格数字对齐、方点不是圆点。橙色<b>只给「正在跑」</b>，别处一律不许出现。",
    fit: "这是一台<b>驱动 agent 的仪器</b>。热口音只标一件事——现在什么在动——所以一眼就知道该看哪。读数常驻，不用点开。",
    risk: "标签全大写对中文不友好，得混排。橙色一旦滥用立刻塌。",
  },
  {
    id: "phosphor",
    zh: "磷光",
    en: "Phosphor",
    sw: ["#0b0c0b", "#ffb000", "#2a2f28"],
    blurb: "整机等宽、字符网格、琥珀",
    thesis:
      "把终端做好看，而不是做旧。全窗等宽、行高锁 20px 对齐字符格、方点、块状光标、琥珀单口音。不加扫描线、不加噪点、不做拟物。",
    fit: "这个 agent 的主业就是<b>跑 shell、改文件</b>。终端美学不是隐喻，是它真实的工作面；`bash` 输出在这里最不违和。",
    risk: "最容易滑向 cosplay。中文在等宽里排版会松，需要单独调。",
  },
  {
    id: "web",
    zh: "官方 web",
    en: "Web reference",
    sw: ["#fff", "#2b2d31", "#e6e6e9"],
    blurb: "参照系 · 官方今天的样子",
    thesis: "官方 dsh web 现在的样子，用它自己的灰阶画的。放这里是为了量差距。",
    fit: "右栏那个详情面板<b>在发布版里没有入口</b>——openDetails 有实现但无人调用。其余五套都把它接上了。",
    risk: "—",
  },
];

const STRUCTS = [
  { id: "console", zh: "控制台", note: "详情面板接通：点工具行展开输入 / 输出 / 计时。" },
  { id: "bench", zh: "工作台", note: "右边常驻工作面：diff、终端、文件页签，跟着 agent 走。" },
  { id: "ledger", zh: "账本", note: "Trajectory 提为主表面：时间轴按真实耗时投影。" },
];

const state = { a: "blueprint", b: "web", s: "console", scene: "session", mode: "light", pg: "light", cmp: false, focus: "a" };
const hosts = { a: document.getElementById("host-a"), b: document.getElementById("host-b") };
const runs = new WeakMap();
const anim = !window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const skinById = (id) => SKINS.find((s) => s.id === id) || SKINS[0];
const wait = (ms) => new Promise((r) => setTimeout(r, anim ? ms : 0));
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
function el(tag, cls, html) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
}

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

/* ————— 代码窗 ————— */

function readFrame(node, bare) {
  const f = el("div", "codeframe");
  if (!bare) f.append(el("div", "cf-bar", `<span class="cf-name">${esc(node.title)}</span><button class="cf-act">复制</button>`));
  const code = el("pre", "code");
  node.code.forEach((line, i) => code.append(el("div", "ln", `<span class="no">${node.startLine + i}</span><span class="tx">${hl(line)}</span>`)));
  f.append(code);
  return f;
}

function diffFrame(node, bare) {
  const f = el("div", "codeframe");
  if (!bare) f.append(el("div", "cf-bar", `<span class="cf-name">${esc(node.title)}</span><button class="cf-act">复制</button>`));
  const code = el("pre", "code");
  node.diff.forEach((r) => {
    const cls = r.op === "+" ? "add" : r.op === "-" ? "del" : "";
    code.append(el("div", `ln dl ${cls}`, `<span class="no">${r.op.trim()}</span><span class="tx">${hl(r.text)}</span>`));
  });
  f.append(code);
  f.append(el("div", "dfoot", `└ ${node.meta}`));
  return f;
}

function termFrame(node, bare) {
  const f = el("div", "codeframe");
  if (!bare) f.append(el("div", "cf-bar", `<span class="cf-name">${esc(node.cwd)}</span><span class="tmeta">${esc(node.meta)}</span>`));
  const t = el("pre", "term");
  t.append(el("div", null, `<span class="pr">$ </span>${esc(node.cmd)}`));
  f.append(t);
  return f;
}

const frameFor = (n, bare) => (n.render === "diff" ? diffFrame(n, bare) : n.render === "terminal" ? termFrame(n, bare) : readFrame(n, bare));

async function printTerm(root, node, alive) {
  const t = root?.querySelector(".term");
  if (!t) return;
  for (const line of node.out) {
    if (!alive()) return;
    const row = el("div", null, `<span class="dim shim">${esc(line)}</span>`);
    t.append(row);
    await wait(320);
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
    box.append(el("button", "ws-h", `<span class="caret">${ws.open ? "▾" : "▸"}</span><b>${ws.name}</b><em>${ws.sessions.length}</em>`));
    if (ws.open) {
      const list = el("ul", "ses");
      ws.sessions.forEach((se) => {
        const cur = se.state === "current";
        const dot = cur ? (scene === "approval" ? "wait" : "running") : se.state;
        const li = el("li", cur ? "cur" : "");
        li.innerHTML = `<span class="sdot ${dot}"></span><span class="s-t">${se.title}</span><span class="s-when">${
          cur && scene === "approval" ? "待审批" : se.detail || se.when
        }</span>`;
        list.append(li);
      });
      box.append(list);
    }
    s.append(box);
  });
  s.append(el("div", "side-foot", `<span>设置</span><span>插件 12</span>`));
  return s;
}

/* ————— 节点 ————— */

function nodeEl(node, struct) {
  if (node.kind === "user") {
    const n = el("div", "node n-user");
    n.innerHTML = `<div class="n-meta">你 · ${node.time}</div>`;
    n.append(el("p", null, esc(node.text)));
    return n;
  }
  if (node.kind === "assistant") {
    const n = el("div", "node n-asst");
    if (node.reasoning) {
      const d = el("details", "think");
      d.innerHTML = `<summary><span class="think-k">思考</span><span class="think-s">${esc(node.reasoning[0])}</span></summary>`;
      const b = el("div", "think-body");
      node.reasoning.forEach((l) => b.append(el("p", null, esc(l))));
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

  const n = el("div", "node tool run");
  const head = el("button", "tool-h");
  head.innerHTML = `<span class="tname">${node.tool}</span><span class="ttitle">${esc(node.title)}</span><span class="tmeta">${esc(node.meta)}</span><span class="tstate"></span>`;
  n.append(head);
  if (struct !== "bench") {
    const body = el("div", "tool-b");
    body.append(frameFor(node, true));
    n.append(body);
    head.addEventListener("click", () => n.classList.toggle("open"));
  }
  return n;
}

/* ————— 轨迹 ————— */

const SPAN_TOTAL = 12400;

function trajectory() {
  const wrap = el("div", "center");
  const tl = el("div", "tl");
  tl.append(el("div", "tl-h", `<b>概览</b><em>轮 3 · 12.4s · 拖选可筛，滚轮缩放</em>`));
  const track = el("div", "tl-track");
  LEDGER.forEach((row) => {
    const who = row.who === "asst" ? "asst" : row.who === "tool" ? "tool" : row.type.startsWith("approval") ? "wait" : "";
    const bar = el("div", `tl-bar ${who}`);
    bar.style.left = `${(row.ms / SPAN_TOTAL) * 100}%`;
    bar.style.width = `${Math.max(((row.span * 100) / SPAN_TOTAL) * 100, 0.8)}%`;
    bar.style.top = `${row.who === "asst" ? 3 : row.who === "tool" ? 13 : 23}px`;
    bar.title = `${row.type} · ${(row.ms / 1000).toFixed(1)}s`;
    track.append(bar);
  });
  tl.append(track, el("div", "tl-ticks", `<span>0s</span><span>3s</span><span>6s</span><span>9s</span><span>12s</span>`));
  wrap.append(tl);

  const scroll = el("div", "flow");
  scroll.style.padding = "0";
  const table = el("table", "led");
  table.innerHTML = `<thead><tr><th>#</th><th>事件</th><th>内容</th><th style="text-align:right">耗时</th></tr></thead>`;
  const tb = el("tbody");
  LEDGER.forEach((row, i) => {
    const tr = el("tr", i === 8 ? "sel" : "");
    tr.innerHTML =
      `<td class="lq">${row.seq}</td><td class="lt">${row.type}${row.surface ? '<span class="surf"></span>' : ""}</td>` +
      `<td class="lc">${esc(row.text)}</td><td class="lm">${(row.ms / 1000).toFixed(1)}s</td>`;
    tr.addEventListener("click", () => {
      tb.querySelectorAll("tr").forEach((n) => n.classList.remove("sel"));
      tr.classList.add("sel");
    });
    tb.append(tr);
  });
  table.append(tb);
  scroll.append(table);
  wrap.append(scroll);
  return wrap;
}

/* ————— 右栏 ————— */

function detailsRail(skin, scene) {
  const r = el("aside", "rail");
  r.append(el("div", "rail-h", `<b>详情</b><em>${skin === "web" ? "无入口" : "read · 42–61"}</em>`));
  if (skin === "web") {
    r.append(
      el("div", "empty", `<p>点消息流里的工具行查看详情。</p><p class="deadnote">openDetails 已实现但无人调用<br />这一栏在发布版里打不开</p>`)
    );
    return r;
  }
  const s1 = el("div", "sect");
  s1.append(el("h4", null, "输入"));
  s1.append(el("dl", "kv", `<dt>tool</dt><dd class="mono">read</dd><dt>path</dt><dd class="mono">app/…/WorkspaceStore.swift</dd><dt>range</dt><dd class="mono">42–61</dd>`));
  r.append(s1);
  const s2 = el("div", "sect");
  s2.append(el("h4", null, "输出"));
  const f = readFrame(NODES[2], true);
  f.querySelector(".code").style.maxHeight = "160px";
  s2.append(f);
  r.append(s2);
  const s3 = el("div", "sect");
  s3.append(el("h4", null, "计时"));
  s3.append(el("dl", "kv", `<dt>排队</dt><dd class="mono">12ms</dd><dt>执行</dt><dd class="mono">688ms</dd><dt>token</dt><dd class="mono">1,204</dd>`));
  r.append(s3);
  const s4 = el("div", "sect");
  s4.append(el("h4", null, "会话"));
  s4.append(el("dl", "kv", `<dt>模式</dt><dd>${SESSION.preset}</dd><dt>访问</dt><dd>${SESSION.accessLabel}</dd><dt>profile</dt><dd class="mono">studio</dd><dt>桥</dt><dd class="mono">127.0.0.1:43180</dd>`));
  r.append(s4);
  return r;
}

function benchRail() {
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
  term.out.forEach((l) => t.append(el("div", null, `<span class="dim">${esc(l)}</span>`)));
  b.append(bot);
  return b;
}

function ledgerRail() {
  const r = el("aside", "rail");
  r.append(el("div", "rail-h", `<b>记录</b><em>#132</em>`));
  const s1 = el("div", "sect");
  s1.append(el("h4", null, "tool/call"));
  s1.append(el("dl", "kv", `<dt>tool</dt><dd class="mono">bash</dd><dt>轮 / 步</dt><dd class="mono">3 / 2</dd><dt>surface</dt><dd class="mono">否</dd>`));
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
  s4.append(el("h4", null, "本轮"));
  s4.append(el("dl", "kv", `<dt>轮 · 步</dt><dd class="mono">3 · 7</dd><dt>LLM</dt><dd class="mono">${SESSION.stats.llm}</dd><dt>工具</dt><dd class="mono">${SESSION.stats.tools}</dd><dt>缓存</dt><dd class="mono">${SESSION.stats.cache}%</dd>`));
  r.append(s4);
  return r;
}

/* ————— composer ————— */

function composerStack(skin, scene) {
  const dock = el("div", "dock");
  const st = SESSION.stats;
  dock.append(
    el(
      "div",
      "strip",
      `<span>${st.turns} 轮 · ${st.steps} 步</span><span class="sep">·</span><span>LLM ${st.llm}</span><span class="sep">·</span>` +
        `<span>工具 ${st.tools}</span><span class="sep">·</span><span>首 token ${st.ttft}</span><span class="sep">·</span>` +
        `<span>${st.tps} tok/s</span><span class="sep">·</span><span>缓存 ${st.cache}%</span>`
    )
  );
  const todos = el("div", "todos");
  todos.append(el("span", "tk", "任务"));
  TODOS.forEach((t) => todos.append(el("span", `todo ${t.done ? "done" : ""} ${t.active ? "now" : ""}`, `<b></b>${t.text}`)));
  dock.append(todos);

  const wrap = el("div", "cwrap");
  if (scene === "approval") {
    const ap = NODES.find((n) => n.kind === "approval");
    const panel = el("div", "approve");
    panel.innerHTML =
      `<div class="ap-top"><span class="ap-k">等待审批</span><span class="ap-r">${esc(ap.reason)}</span></div>` +
      `<div class="ap-cmd">${esc(ap.command)}</div><div class="ap-note">${esc(ap.note)}</div>`;
    const btns = el("div", "ap-btns");
    btns.append(el("button", "btn btn-primary", "允许一次"), el("button", "btn", "拒绝"));
    if (skin !== "web") {
      const g = el("label", "ap-grant");
      g.innerHTML = `<input type="checkbox" />本会话内记住 bash`;
      btns.append(g);
    }
    panel.append(btns);
    wrap.append(panel);
    dock.append(wrap);
    return dock;
  }

  const c = el("div", "composer");
  c.innerHTML = `<div class="crow1"><button class="plus">+</button><textarea rows="1" placeholder="给智能体写点什么，或按 / 唤起命令" aria-label="输入"></textarea></div>`;
  const pct = Math.round((SESSION.context.used / SESSION.context.capacity) * 100);
  c.append(
    el(
      "div",
      "crow2",
      `<span class="cchips"><button class="chip">访问 · ${SESSION.accessLabel}</button><button class="chip">计划 · 关</button>` +
        `<button class="chip">${SESSION.model} · ${SESSION.effort}</button></span>` +
        `<span class="ringwrap"><span class="ring" style="background:conic-gradient(var(--field) 0 ${pct}%, var(--line2) ${pct}% 100%)"></span>${pct}%</span>` +
        `<button class="send">↑</button>`
    )
  );
  wrap.append(c, el("div", "slash"));
  dock.append(wrap);
  return dock;
}

/* ————— 组装 ————— */

function buildApp(skin, struct, scene, mode) {
  const app = el("div", "app");
  app.dataset.k = skin;
  app.dataset.s = struct;
  app.dataset.scene = scene;
  app.dataset.m = mode;

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

  // 中栏 = 一张浮起的画布 + 一层单独浮起的输入栏，不是一根到底的边框柱。
  const asLedger = scene === "trajectory" || struct === "ledger";
  const center = el("div", "center");
  const sheet = el("div", "sheet");

  if (scene === "hero") {
    const hero = el("div", "hero");
    hero.innerHTML = `<span class="hero-badge">Preview</span><h2>探索未至之境</h2><p class="lede">选一个工作区就能开始。会话跟着文件夹走。</p>`;
    hero.append(el("button", "hero-pick", `<b>选择工作区</b><span>原生对话框 · 最近用过 4 个</span>`));
    sheet.append(hero);
  } else {
    const head = el("div", "chead");
    head.innerHTML = `<h1>${SESSION.title}</h1>`;
    const tabs = el("div", "vtabs");
    tabs.innerHTML = asLedger
      ? `<button>Chat</button><button class="on">Trajectory</button>`
      : `<button class="on">Chat</button><button>Trajectory</button>`;
    head.append(tabs);
    if (!asLedger) head.append(el("button", "btn btn-sm ghost", "子智能体 2"));
    sheet.append(head);
    if (asLedger) {
      const t = trajectory();
      while (t.firstChild) sheet.append(t.firstChild);
    } else {
      sheet.append(el("div", "flow"));
    }
  }

  center.append(sheet, composerStack(skin, scene));
  body.append(center);

  if (struct === "bench") body.append(benchRail());
  else if (struct === "ledger") body.append(ledgerRail());
  else body.append(detailsRail(skin, scene));
  app.append(body);

  const sc = SCENES[scene];
  app.append(
    el(
      "footer",
      "sbar",
      `<span class="dot ${sc.tone === "wait" ? "wait" : ""}"></span><span>${sc.status}</span>` +
        `<span class="right"><span>${SESSION.preset}</span><span>3080 · 43180</span></span>`
    )
  );
  return app;
}

async function play(app) {
  const token = {};
  runs.set(app, token);
  const alive = () => runs.get(app) === token && app.isConnected;
  const flow = app.querySelector(".flow");
  if (!flow || app.dataset.scene === "hero" || app.querySelector(".led")) return;
  flow.replaceChildren();

  const struct = app.dataset.s;
  const stop = app.dataset.scene === "approval" ? NODES.findIndex((n) => n.kind === "approval") : NODES.length;

  for (let i = 0; i < stop; i += 1) {
    if (!alive()) return;
    const node = NODES[i];
    const n = nodeEl(node, struct);
    if (!n) continue;
    n.classList.add("enter");
    flow.append(n);
    flow.scrollTop = flow.scrollHeight;
    if (node.kind === "tool") {
      await wait(node.ms);
      if (!alive()) return;
      if (node.render === "terminal" && struct !== "bench") {
        n.classList.add("open");
        await printTerm(n.querySelector(".tool-b"), node, alive);
      }
      n.classList.remove("run");
      n.classList.add("ok");
      if (struct !== "bench" && node.render === "diff") n.classList.add("open");
    } else {
      await wait(340);
    }
    flow.scrollTop = flow.scrollHeight;
  }
  if (app.dataset.scene === "approval") {
    const last = flow.querySelector(".tool:last-of-type");
    if (last) {
      last.classList.remove("ok");
      last.classList.add("run");
    }
  }
}

/* ————— / 菜单 ————— */

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
  SLASH.forEach((it, i) => {
    const b = el("button", i === 0 ? "on" : "");
    b.innerHTML = `<span class="sn">${it.name}</span><span class="sh">${it.hint}</span><span class="sd">${it.desc}</span>`;
    b.addEventListener("click", () => {
      ta.value = `${it.name} `;
      menu.classList.remove("open");
      ta.focus();
    });
    menu.append(b);
  });
  const wrap = app.querySelector(".cwrap");
  if (atCaret) {
    const p = caretXY(ta);
    menu.style.left = `${Math.max(0, Math.min(p.x, wrap.clientWidth - 330))}px`;
    menu.style.bottom = `${wrap.clientHeight - p.y + 4}px`;
  } else {
    menu.style.left = "13px";
    menu.style.bottom = `${wrap.clientHeight - 6}px`;
  }
  menu.classList.add("open");
}

function bind(app) {
  const ta = app.querySelector("textarea");
  if (!ta) return;
  ta.addEventListener("input", () => {
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 92)}px`;
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
    n.innerHTML = `<div class="n-meta">你 · 排队</div>`;
    n.append(el("p", null, text));
    flow.append(n);
    flow.scrollTop = flow.scrollHeight;
  }
  ta.value = "";
  ta.style.height = "auto";
}

/* ————— 外壳 ————— */

function mount(w) {
  const app = buildApp(state[w], state.s, state.scene, state.mode);
  hosts[w].replaceChildren(app);
  bind(app);
  play(app);
  const cap = document.querySelector(`[data-win="${w}"] figcaption b`);
  if (cap) cap.textContent = `${skinById(state[w]).zh} · ${STRUCTS.find((s) => s.id === state.s).zh}`;
}
const mountAll = () => {
  mount("a");
  if (state.cmp) mount("b");
};

function renderSkins() {
  const side = document.querySelector(".pg-side");
  side.querySelectorAll(".skin").forEach((n) => n.remove());
  SKINS.forEach((s, i) => {
    const c = el("button", "skin");
    c.dataset.k = s.id;
    c.innerHTML =
      `<span class="sk-h"><span class="sw">${s.sw.map((h) => `<i style="background:${h}"></i>`).join("")}</span>` +
      `<b>${s.zh}</b><em>${i + 1}</em></span><p>${s.blurb}</p>`;
    c.addEventListener("click", () => pickSkin(s.id));
    side.append(c);
  });
  syncSkins();
}
const syncSkins = () =>
  document.querySelectorAll(".skin").forEach((c) => c.classList.toggle("on", c.dataset.k === state[state.focus]));

function renderStructs() {
  const box = document.getElementById("structs");
  box.replaceChildren();
  STRUCTS.forEach((s) => {
    const b = el("button", s.id === state.s ? "on" : "", s.zh);
    b.addEventListener("click", () => setStruct(s.id));
    box.append(b);
  });
}

function renderNotes() {
  const s = skinById(state[state.focus]);
  const st = STRUCTS.find((x) => x.id === state.s);
  document.querySelector(".pg-notes").innerHTML =
    `<p class="eb">皮肤</p><h3>${s.zh}</h3><p class="sub">${s.en}</p><p>${s.thesis}</p>` +
    `<dl><dt>为什么适合 agent</dt><dd>${s.fit}</dd><dt>代价</dt><dd>${s.risk}</dd>` +
    `<dt>当前结构 · ${st.zh}</dt><dd>${st.note}</dd></dl>`;
}

function pickSkin(id) {
  state[state.focus] = id;
  mount(state.focus);
  syncSkins();
  renderNotes();
  hash();
}
function setStruct(id) {
  state.s = id;
  renderStructs();
  mountAll();
  renderNotes();
  hash();
}
function setScene(sc) {
  state.scene = sc;
  document.querySelectorAll("#scenes button").forEach((b) => b.classList.toggle("on", b.dataset.scene === sc));
  mountAll();
  hash();
}
function setMode(m) {
  state.mode = m;
  document.querySelectorAll("[data-mode]").forEach((b) => b.classList.toggle("on", b.dataset.mode === m));
  mountAll();
  hash();
}
function setPg(v) {
  state.pg = v;
  document.body.dataset.pg = v;
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
  syncSkins();
  renderNotes();
  hash();
}

function hash() {
  const p = new URLSearchParams({ k: state.a, s: state.s, scene: state.scene, m: state.mode });
  if (state.pg === "dark") p.set("pg", "dark");
  if (state.cmp) {
    p.set("cmp", "1");
    p.set("b", state.b);
  }
  history.replaceState(null, "", `#${p}`);
}
function readHash() {
  const p = new URLSearchParams(location.hash.slice(1));
  const ids = SKINS.map((s) => s.id);
  if (ids.includes(p.get("k"))) state.a = p.get("k");
  if (ids.includes(p.get("b"))) state.b = p.get("b");
  if (STRUCTS.some((s) => s.id === p.get("s"))) state.s = p.get("s");
  if (SCENES[p.get("scene")]) state.scene = p.get("scene");
  if (["light", "dark"].includes(p.get("m"))) state.mode = p.get("m");
  if (p.get("pg") === "dark") state.pg = "dark";
  if (p.get("cmp") === "1") state.cmp = true;
}

document.querySelectorAll("#scenes button").forEach((b) => b.addEventListener("click", () => setScene(b.dataset.scene)));
document.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => setMode(b.dataset.mode)));
document.querySelector('[data-act="cmp"]').addEventListener("click", toggleCmp);
document.querySelector('[data-act="replay"]').addEventListener("click", mountAll);
document.querySelector('[data-act="pg"]').addEventListener("click", () => setPg(state.pg === "light" ? "dark" : "light"));
document.querySelectorAll(".frame").forEach((f) =>
  f.addEventListener("mousedown", () => {
    if (!state.cmp) return;
    state.focus = f.dataset.win;
    document.querySelectorAll(".frame").forEach((n) => n.classList.toggle("on", n === f));
    syncSkins();
    renderNotes();
  })
);

window.addEventListener("keydown", (e) => {
  if (["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName)) {
    if (e.key === "Escape") document.querySelectorAll(".slash").forEach((m) => m.classList.remove("open"));
    return;
  }
  const n = Number(e.key);
  if (n >= 1 && n <= SKINS.length) pickSkin(SKINS[n - 1].id);
  const k = e.key.toLowerCase();
  const scenes = { q: "session", w: "approval", e: "trajectory", r: "hero" };
  if (scenes[k]) setScene(scenes[k]);
  if (k === "s") setStruct(STRUCTS[(STRUCTS.findIndex((x) => x.id === state.s) + 1) % STRUCTS.length].id);
  if (k === "c") toggleCmp();
  if (k === "d") setMode(state.mode === "light" ? "dark" : "light");
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
document.body.dataset.pg = state.pg;
document.querySelectorAll("[data-mode]").forEach((b) => b.classList.toggle("on", b.dataset.mode === state.mode));
document.querySelectorAll("#scenes button").forEach((b) => b.classList.toggle("on", b.dataset.scene === state.scene));
document.querySelector('[data-act="cmp"]').setAttribute("aria-pressed", String(state.cmp));
document.querySelector(".pg-stage").dataset.cmp = String(state.cmp);
document.querySelector('[data-win="b"]').hidden = !state.cmp;
renderStructs();
renderSkins();
mountAll();
renderNotes();
hash();
