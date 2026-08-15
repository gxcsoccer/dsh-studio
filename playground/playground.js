const STRUCTURES = [
  {
    id: "manuscript",
    name: "Manuscript",
    nameZh: "手稿",
    tag: "编辑性最强",
    swatch: ["#f6f5f4", "#ffb110", "#02093a"],
    thesis:
      "没有左侧栏。工作区是顶部的纸质书签，正文独占一栏，工具调用退到页边当批注——像书里的边注，不抢正文。标题按 60px 排，lede 用衬线。",
    motion: "正文流式写出；页边批注在对应段落旁淡入，带一条细引线。",
    cost: "页边在窄窗口会塌回正文下方。检查器要折进顶部书签。",
    pick: "会话本身就是产物、要能读能引用的时候。最像「文档」，最不像 IDE。",
  },
  {
    id: "diptych",
    name: "Diptych",
    nameZh: "双联",
    tag: "最像那一页",
    swatch: ["#ffffff", "#fff4d4", "#02093a"],
    thesis:
      "左文右台。左边永远是叙述，右边是整块色的舞台，工具在上面演：读文件是杏色，改代码是天蓝，跑命令是午夜蓝，要审批转珊瑚。色块随活动换，是状态本身。",
    motion: "舞台整块换色 320ms，卡片贴着色块推上来；左边文字不动。",
    cost: "宽度吃得多，1180 以下要把舞台压成抽屉。",
    pick: "要 notion.com/product/dev 那种「文案 + 活的代码窗」的双联节奏。",
  },
  {
    id: "blocks",
    name: "Blocks",
    nameZh: "块",
    tag: "每天用",
    swatch: ["#ffffff", "#e6f3fe", "#111111"],
    thesis:
      "真正的块编辑器。悬停出句柄，/ 菜单从光标处长出来而不是屏幕中央，工具是能折叠的 callout，检查器是页面属性那一套小标签。",
    motion: "块 160ms 就位；/ 菜单锚在光标的实际像素位置。",
    cost: "最朴素。截图不出彩，但每天八小时不累。",
    pick: "把 Studio 当工作区而不是展台。长期驻留、大量翻旧会话。",
  },
  {
    id: "current",
    name: "Current",
    nameZh: "当前",
    tag: "对照",
    swatch: ["#0b0b0c", "#d4a574", "#131316"],
    thesis:
      "仓库里现在的样子。语义 token 是对的，但布局是三栏工具壳：会话挤在中间，工具调用没有位置，标题只有 22px。",
    motion: "线性淡出 120ms。",
    cost: "——",
    pick: "只用来量差距。",
  },
];

const state = {
  a: "diptych",
  b: "manuscript",
  scene: "session",
  appearance: "day",
  compare: false,
  focus: "a",
};

const hosts = { a: document.getElementById("host-a"), b: document.getElementById("host-b") };
const players = new WeakMap();
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const byId = (id) => STRUCTURES.find((s) => s.id === id) || STRUCTURES[0];
const wait = (ms) => new Promise((r) => setTimeout(r, reduceMotion ? Math.min(ms, 60) : ms));
const el = (tag, cls, html) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (html != null) node.innerHTML = html;
  return node;
};
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const KEYWORDS =
  /\b(func|let|var|if|else|return|struct|final|class|enum|await|async|import|self|guard|try|case|switch|private|public|static|extension|throws|in|for|while|true|false|nil|null|const|export|new|Task)\b/g;

function hl(line) {
  const pieces = [];
  let rest = line;
  const re = /(\/\/[^\n]*|"(?:[^"\\]|\\.)*")/;
  let m;
  while ((m = re.exec(rest))) {
    if (m.index > 0) pieces.push(["code", rest.slice(0, m.index)]);
    pieces.push([m[0].startsWith("//") ? "cm" : "str", m[0]]);
    rest = rest.slice(m.index + m[0].length);
  }
  pieces.push(["code", rest]);
  return pieces
    .map(([kind, value]) => {
      const safe = esc(value);
      if (kind !== "code") return `<i class="${kind}">${safe}</i>`;
      return safe
        .replace(KEYWORDS, '<i class="kw">$1</i>')
        .replace(/\b([A-Z][A-Za-z0-9_]+)\b/g, '<i class="ty">$1</i>')
        .replace(/\b(\d+(?:\.\d+)?)\b/g, '<i class="nm">$1</i>');
    })
    .join("");
}

function codeWindow({ file, lang, range, code, diff, added, removed }) {
  const card = el("div", "codewin");
  const head = el("header");
  head.append(
    el("span", "fname", esc(file)),
    el("span", "lang", lang || ""),
    el("span", "meta", diff ? `+${added} −${removed}` : range ? `${range} 行` : "")
  );
  card.append(head);
  const body = el("div", "cbody");
  const rows = diff
    ? diff.map((row, i) => {
        const line = el("div", `crow op${row.op === "+" ? "add" : row.op === "-" ? "del" : "ctx"}`);
        line.append(el("span", "gut", row.op === " " ? String(i + 1) : row.op), el("code", null, hl(row.text)));
        return line;
      })
    : code.map((text, i) => {
        const line = el("div", "crow");
        line.append(el("span", "gut", String(i + 1)), el("code", null, hl(text)));
        return line;
      });
  rows.forEach((r) => body.append(r));
  card.append(body);
  return card;
}

function terminalWindow({ cmd, out, ok }) {
  const card = el("div", "codewin term");
  const head = el("header");
  head.append(el("span", "fname", "zsh"), el("span", "meta", ok ? "exit 0" : "exit 1"));
  card.append(head);
  const body = el("div", "cbody");
  body.append(el("div", "crow", `<span class="gut">$</span><code><i class="cmd">${esc(cmd)}</i></code>`));
  out.forEach((line) => body.append(el("div", "crow", `<span class="gut"></span><code class="dim">${esc(line)}</code>`)));
  card.append(body);
  return card;
}

const ACTIVITY = {
  think: { tint: "midnight", label: "思考" },
  read: { tint: "gold", label: "读取" },
  edit: { tint: "sky", label: "编辑" },
  run: { tint: "midnight", label: "运行" },
  approve: { tint: "coral", label: "待批准" },
};

/** 工具在正文里是完整卡片，还是压成一行、把内容让给别处（页边 / 舞台）。 */
const TRACE_LAYOUT = { manuscript: true, diptych: true, blocks: false, current: false };

function traceSummary(item) {
  if (item.kind === "edit") return `${item.file}  +${item.added} −${item.removed}`;
  if (item.kind === "read") return `${item.file}:${item.range}`;
  if (item.kind === "run") return item.cmd;
  return item.title || `${item.lines.length} 条推理`;
}

/* ————— 结构骨架 ————— */

function railMarkup(style) {
  const rail = el("aside", "rail");
  rail.append(el("button", "search", `<span>搜索会话</span><kbd>/</kbd>`));
  rail.append(el("p", "kicker", "工作区"));
  const ws = el("button", "ws is-on");
  ws.innerHTML = `<span class="ws-mark">ds</span><span class="ws-copy"><strong>dsh-studio</strong><small>3 个会话 · 已恢复</small></span>`;
  rail.append(ws);
  rail.append(el("p", "kicker", "会话"));
  const list = el("ul", "pages");
  [
    ["把侧栏做成工作区书签", "刚刚", true],
    ["主题 token 热更新", "2 小时前", false],
    ["首次运行检查文案", "昨天", false],
  ].forEach(([title, when, on]) => {
    const li = el("li", on ? "is-on" : "");
    li.innerHTML = `<span class="page-ico"></span><span class="page-t">${title}</span><span class="page-w">${when}</span>`;
    list.append(li);
  });
  rail.append(list);
  rail.append(el("p", "kicker", "最近"));
  const recents = el("ul", "recents");
  ["harness-docs", "studio-plugin"].forEach((r) => recents.append(el("li", null, r)));
  rail.append(recents);
  rail.append(el("div", "rail-foot", "官方运行时 · base + 1 层"));
  return rail;
}

function propsMarkup(style, scene) {
  const lens = el("aside", "lens");
  const phase = SCENES[scene].phase;
  const tone = SCENES[scene].status[1];
  if (style === "blocks") {
    lens.append(el("p", "kicker", "页面属性"));
    const props = el("div", "nprops");
    [
      ["阶段", phase, tone],
      ["桥", tone === "bad" ? "未连接" : "127.0.0.1:43180", ""],
      ["Profile", "studio", ""],
      ["密钥", "钥匙串", "ok"],
      ["工作区", "dsh-studio", ""],
    ].forEach(([k, v, tone]) => {
      const row = el("div", "nprop");
      row.innerHTML = `<span class="pk">${k}</span><span class="pv ${tone}">${v}</span>`;
      props.append(row);
    });
    lens.append(props);
    lens.append(el("p", "kicker", "插件层"));
    const layers = el("ul", "layers");
    [
      ["1", "@deepseek-ai/dsh-base", "gold"],
      ["2", "dsh-studio bundle", "sky"],
      ["3", "profile patch", "mocha"],
    ].forEach(([n, name, tint]) => {
      const li = el("li", `t-${tint}`);
      li.innerHTML = `<span>${n}</span>${name}`;
      layers.append(li);
    });
    lens.append(layers);
    return lens;
  }
  lens.append(el("p", "kicker", "检查器"));
  const props = el("dl", "props");
  [
    ["阶段", phase],
    ["桥", tone === "bad" ? "未连接" : "127.0.0.1:43180"],
    ["Profile", "studio"],
    ["密钥", "钥匙串"],
  ].forEach(([k, v]) => {
    const row = el("div");
    row.innerHTML = `<dt>${k}</dt><dd>${v}</dd>`;
    props.append(row);
  });
  lens.append(props);
  lens.append(el("p", "kicker", "插件层"));
  const layers = el("ul", "layers");
  [
    ["1", "@deepseek-ai/dsh-base", "gold"],
    ["2", "dsh-studio bundle", "sky"],
    ["3", "profile patch", "mocha"],
  ].forEach(([n, name, tint]) => {
    const li = el("li", `t-${tint}`);
    li.innerHTML = `<span>${n}</span>${name}`;
    layers.append(li);
  });
  lens.append(layers);
  return lens;
}

function composerMarkup(style) {
  const dock = el("div", "dock");
  const composer = el("div", "composer");
  composer.innerHTML = `
    <textarea rows="1" placeholder="写给 Agent，或按 / 插入" aria-label="写给 Agent"></textarea>
    <div class="composer-foot">
      <span class="ctx"><i class="ctx-dot"></i>dsh-studio · 全部文件</span>
      <button type="button" class="btn btn-primary send">发送 <kbd>⌘⏎</kbd></button>
    </div>`;
  dock.append(composer);
  dock.append(el("div", "slash", ""));
  return dock;
}

function pageHead(scene, style) {
  const data = SCENES[scene];
  const head = el("header", "page-head");
  head.append(el("p", "kicker", data.kicker));
  const h1 = el("h1");
  h1.innerHTML = `${esc(data.title[0])}<em>${esc(data.title[1])}</em>`;
  head.append(h1);
  head.append(el("p", "lede", data.lede));
  return head;
}

function sceneExtras(scene) {
  const data = SCENES[scene];
  const wrap = el("div", "scene-extra");
  if (data.checks) {
    const list = el("ul", "checks");
    data.checks.forEach((c) => {
      const li = el("li", c.state);
      li.innerHTML = `<span class="ck-mark"></span><span class="ck-copy"><strong>${c.title}</strong><small>${c.detail}</small></span>`;
      list.append(li);
    });
    wrap.append(list);
  }
  if (scene === "empty") {
    const drop = el("div", "drop");
    drop.innerHTML = `<strong>把文件夹拖到这里</strong><small>或从最近的选一个</small>`;
    wrap.append(drop);
  }
  if (data.log) {
    wrap.append(terminalWindow({ cmd: "dsh --profile studio", out: data.log, ok: false }));
  }
  if (data.actions) {
    const row = el("div", "cta-row");
    data.actions.forEach(([label, primary]) => {
      row.append(el("button", `btn${primary ? " btn-primary" : ""}`, label));
    });
    wrap.append(row);
  }
  return wrap;
}

function buildWindow(styleId, scene, appearance) {
  const mac = el("div", "mac");
  mac.dataset.style = styleId;
  mac.dataset.scene = scene;
  mac.dataset.appearance = styleId === "current" ? (appearance === "dusk" ? "dusk" : "day") : appearance;
  mac.tabIndex = 0;

  const chrome = el("header", "chrome");
  chrome.innerHTML = `<div class="traffic" aria-hidden="true"><i></i><i></i><i></i></div>`;
  if (styleId === "manuscript") {
    const tabs = el("div", "tabs");
    ["dsh-studio", "harness-docs", "+"].forEach((t, i) => {
      tabs.append(el("button", `tab${i === 0 ? " is-on" : ""}${t === "+" ? " tab-add" : ""}`, t));
    });
    chrome.append(tabs);
    chrome.append(el("div", "chrome-right", `<span class="live"><i></i>已就绪</span>`));
  } else {
    chrome.append(
      el("div", "chrome-id", `<span class="wordmark">dsh-studio</span><span class="crumb">会话 · 把侧栏做成工作区书签</span>`)
    );
    const actions = el("div", "chrome-actions");
    actions.append(el("button", "btn", "工作区"), el("button", "btn btn-primary", "新会话"));
    chrome.append(actions);
  }
  mac.append(chrome);

  const shell = el("div", "shell");
  if (styleId !== "manuscript") shell.append(railMarkup(styleId));

  const canvas = el("section", "canvas");
  const scroll = el("div", "scroll");
  scroll.append(pageHead(scene, styleId));
  if (scene === "session") {
    const thread = el("div", "thread");
    scroll.append(thread);
    if (styleId === "manuscript") scroll.append(el("div", "margin-rail"));
  } else {
    scroll.append(sceneExtras(scene));
  }
  canvas.append(scroll);
  canvas.append(composerMarkup(styleId));
  shell.append(canvas);

  if (styleId === "diptych") {
    const stage = el("aside", "stage");
    stage.dataset.tint = "idle";
    stage.innerHTML = `
      <div class="stage-head"><span class="stage-label">舞台</span><span class="stage-sub">工具在这里演</span></div>
      <div class="stage-body"></div>
      <div class="stage-ask"></div>
      <div class="stage-chips"></div>`;
    shell.append(stage);
  } else if (styleId !== "manuscript") {
    shell.append(propsMarkup(styleId, scene));
  }

  mac.append(shell);

  const [statusText, tone] = SCENES[scene].status;
  if (styleId !== "manuscript") {
    const status = el("footer", "status");
    status.innerHTML = `<span class="dot t-${tone}"></span><span class="status-t">${statusText}</span><span class="ports">${
      tone === "bad" ? "— · —" : "3080 · 43180"
    }</span>`;
    mac.append(status);
  } else {
    const live = mac.querySelector(".live");
    if (live) live.innerHTML = `<i class="t-${tone}"></i>${statusText.split(" · ")[0]}`;
  }
  return mac;
}

/* ————— 播放 ————— */

function marginNote(item) {
  const note = el("aside", "mnote");
  const meta = ACTIVITY[item.kind];
  note.innerHTML = `<span class="mnote-k">${meta.label}</span>`;
  if (item.kind === "read") note.append(el("code", null, `${item.file}:${item.range}`));
  if (item.kind === "edit") note.append(el("code", null, `${item.file} +${item.added} −${item.removed}`));
  if (item.kind === "run") note.append(el("code", null, item.cmd));
  if (item.kind === "think") note.append(el("small", null, item.lines[0]));
  return note;
}

function toolBlock(item, style) {
  const meta = ACTIVITY[item.kind];
  const block = el("div", `block tool t-${meta.tint}`);
  const head = el("button", "tool-head");
  head.innerHTML = `
    <span class="handle" aria-hidden="true"></span>
    <span class="tool-k">${meta.label}</span>
    <span class="tool-n">${item.file || item.cmd || item.title || ""}</span>
    <span class="tool-m">${
      item.kind === "edit" ? `+${item.added} −${item.removed}` : item.kind === "read" ? `${item.range} 行` : ""
    }</span>
    <span class="spin" aria-hidden="true"></span>`;
  block.append(head);
  const body = el("div", "tool-body");
  if (item.kind === "read") body.append(codeWindow(item));
  if (item.kind === "edit") body.append(codeWindow(item));
  if (item.kind === "run") body.append(terminalWindow(item));
  if (item.kind === "think") {
    const ul = el("ul", "think-list");
    item.lines.forEach((l) => ul.append(el("li", null, l)));
    body.append(ul);
  }
  block.append(body);
  head.addEventListener("click", () => block.classList.toggle("is-open"));
  return block;
}

function approvalBlock(item) {
  const block = el("div", "block approve");
  block.innerHTML = `
    <div class="ap-copy">
      <strong>${item.title}</strong>
      <small>${item.detail}</small>
    </div>
    <div class="ap-row">
      <button type="button" class="btn btn-primary">${item.accept}</button>
      <button type="button" class="btn">${item.reject}</button>
    </div>`;
  block.querySelectorAll("button").forEach((b) =>
    b.addEventListener("click", () => {
      block.classList.add("is-done");
      block.querySelector(".ap-row").replaceWith(el("span", "ap-done", b.classList.contains("btn-primary") ? "已允许" : "已跳过"));
    })
  );
  return block;
}

async function typeInto(node, text, speed = 12) {
  if (reduceMotion) {
    node.textContent = text;
    return;
  }
  node.textContent = "";
  node.classList.add("typing");
  for (let i = 0; i < text.length; i += 1) {
    node.textContent += text[i];
    if (i % 2 === 0) await wait(speed);
  }
  node.classList.remove("typing");
}

function stageCard(item) {
  if (item.kind === "run") return terminalWindow(item);
  if (item.kind === "think") {
    const box = el("div", "stage-note");
    item.lines.forEach((l) => box.append(el("p", null, l)));
    return box;
  }
  return codeWindow(item);
}

function setStage(mac, item) {
  const stage = mac.querySelector(".stage");
  if (!stage) return;
  const meta = ACTIVITY[item.kind];
  if (!meta) return;
  stage.dataset.tint = meta.tint;
  stage.querySelector(".stage-label").textContent = meta.label;
  stage.querySelector(".stage-sub").textContent = traceSummary(item);

  const ask = stage.querySelector(".stage-ask");
  // 批准的时候要还看得见它想改什么，所以卡片留在台上，问题停靠在下面。
  if (item.kind === "approve") {
    ask.replaceChildren();
    ask.append(el("strong", null, item.title), el("p", null, item.detail));
    const row = el("div", "ap-row");
    row.append(el("button", "btn btn-primary", item.accept), el("button", "btn", item.reject));
    row.querySelectorAll("button").forEach((b) =>
      b.addEventListener("click", () =>
        row.replaceWith(el("span", "ap-done", b.classList.contains("btn-primary") ? "已允许" : "已跳过"))
      )
    );
    ask.append(row);
    ask.classList.add("is-on");
  } else {
    ask.classList.remove("is-on");
    ask.replaceChildren();
    const card = stageCard(item);
    card.classList.add("stage-card");
    stage.querySelector(".stage-body").replaceChildren(card);
  }

  const chips = stage.querySelector(".stage-chips");
  chips.append(el("span", "chip", item.kind === "approve" ? "agent/approval" : `session/event · ${item.kind}`));
  while (chips.children.length > 3) chips.firstChild.remove();
}

async function play(mac) {
  const token = {};
  players.set(mac, token);
  const alive = () => players.get(mac) === token && mac.isConnected;
  const thread = mac.querySelector(".thread");
  if (!thread) return;
  thread.replaceChildren();
  const marginRail = mac.querySelector(".margin-rail");
  if (marginRail) marginRail.replaceChildren();
  const stageBody = mac.querySelector(".stage-body");
  if (stageBody) stageBody.replaceChildren();
  const stageChips = mac.querySelector(".stage-chips");
  if (stageChips) stageChips.replaceChildren();

  const style = mac.dataset.style;
  const scroll = mac.querySelector(".scroll");

  for (const item of TRANSCRIPT) {
    if (!alive()) return;
    await wait(reduceMotion ? 0 : 260);
    if (!alive()) return;

    if (item.kind === "user") {
      const block = el("div", "block user");
      block.innerHTML = `<span class="handle" aria-hidden="true"></span><p></p>`;
      thread.append(block);
      requestAnimationFrame(() => block.classList.add("in"));
      block.querySelector("p").textContent = item.text;
      continue;
    }

    if (item.kind === "say") {
      const block = el("div", "block say");
      block.innerHTML = `<span class="handle" aria-hidden="true"></span><p></p>`;
      thread.append(block);
      requestAnimationFrame(() => block.classList.add("in"));
      await typeInto(block.querySelector("p"), item.text);
      continue;
    }

    setStage(mac, item);

    // 审批在双联上是舞台的事；别处留在正文里，因为它需要被看见。
    if (item.kind === "approve" && style !== "diptych") {
      const block = approvalBlock(item);
      thread.append(block);
      requestAnimationFrame(() => block.classList.add("in"));
      await wait(400);
      if (scroll) scroll.scrollTop = scroll.scrollHeight;
      continue;
    }

    if (TRACE_LAYOUT[style]) {
      const line = el("div", "block trace");
      line.innerHTML = `<span class="trace-k">${ACTIVITY[item.kind].label}</span><code>${esc(
        traceSummary(item)
      )}</code><span class="spin" aria-hidden="true"></span>`;
      thread.append(line);
      requestAnimationFrame(() => line.classList.add("in"));
      if (style === "diptych") {
        line.classList.add("clickable");
        line.addEventListener("click", () => {
          thread.querySelectorAll(".trace.is-on").forEach((n) => n.classList.remove("is-on"));
          line.classList.add("is-on");
          setStage(mac, item);
        });
      }
      await wait(item.ms || 600);
      if (!alive()) return;
      line.classList.add("done");
      if (marginRail) {
        const note = marginNote(item);
        const prev = marginRail.lastElementChild;
        marginRail.append(note);
        // 批注对齐它那一行，但不许压住上一条。
        const floor = prev ? prev.offsetTop + prev.offsetHeight + 12 : 0;
        note.style.setProperty("--top", `${Math.max(line.offsetTop, floor)}px`);
        requestAnimationFrame(() => note.classList.add("in"));
      }
    } else {
      const block = toolBlock(item, style);
      thread.append(block);
      requestAnimationFrame(() => block.classList.add("in"));
      await wait(item.ms || 600);
      if (!alive()) return;
      block.classList.add("done");
      if (item.kind === "edit" || item.kind === "run") block.classList.add("is-open");
    }
    if (scroll) scroll.scrollTop = scroll.scrollHeight;
  }
}

/* ————— / 菜单锚在光标 ————— */

/** 光标在 .composer 坐标系里的像素位置。用一个同字体的镜像 div 量出来。 */
function caretPoint(textarea) {
  const composer = textarea.closest(".composer");
  const cs = getComputedStyle(textarea);
  const mirror = el("div", "caret-mirror");
  ["fontSize", "fontFamily", "fontWeight", "lineHeight", "letterSpacing", "padding", "width"].forEach((p) => {
    mirror.style[p] = cs[p];
  });
  mirror.style.left = `${textarea.offsetLeft}px`;
  mirror.style.top = `${textarea.offsetTop}px`;
  mirror.textContent = textarea.value.slice(0, textarea.selectionStart);
  const marker = el("span", null, "\u200b");
  mirror.append(marker);
  composer.append(mirror);
  const point = { x: marker.offsetLeft, y: marker.offsetTop + parseFloat(cs.lineHeight) || 20 };
  mirror.remove();
  return point;
}

function openSlash(mac, anchorToCaret) {
  const menu = mac.querySelector(".slash");
  const textarea = mac.querySelector("textarea");
  menu.replaceChildren();
  SLASH_ITEMS.forEach((item, i) => {
    const btn = el("button", `${i === 0 ? "is-on" : ""} t-${item.tint}`);
    btn.innerHTML = `<span class="s-dot"></span><strong>${item.title}</strong><span>${item.hint}</span>`;
    btn.addEventListener("click", () => {
      textarea.value = "";
      closeSlash(mac);
      textarea.focus();
    });
    menu.append(btn);
  });
  const dock = mac.querySelector(".dock");
  const composer = mac.querySelector(".composer");
  if (anchorToCaret) {
    const p = caretPoint(textarea);
    const left = composer.offsetLeft + p.x;
    menu.style.left = `${Math.min(left, dock.clientWidth - 268 - 16)}px`;
    menu.style.bottom = `${dock.offsetHeight - composer.offsetTop - p.y - 2}px`;
  } else {
    menu.style.left = `${composer.offsetLeft}px`;
    menu.style.bottom = `${dock.offsetHeight - composer.offsetTop + 6}px`;
  }
  menu.classList.add("is-open");
}

function closeSlash(mac) {
  const menu = mac.querySelector(".slash");
  if (menu) menu.classList.remove("is-open");
}

function bind(mac) {
  const textarea = mac.querySelector("textarea");
  const send = mac.querySelector(".send");
  textarea.addEventListener("input", () => {
    textarea.style.height = "auto";
    textarea.style.height = `${Math.min(textarea.scrollHeight, 120)}px`;
    if (textarea.value.endsWith("/")) openSlash(mac, true);
    else if (!textarea.value.includes("/")) closeSlash(mac);
  });
  textarea.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeSlash(mac);
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey || !e.shiftKey)) {
      e.preventDefault();
      submit(mac);
    }
  });
  send.addEventListener("click", () => submit(mac));
  mac.querySelector(".search")?.addEventListener("click", () => {
    textarea.focus();
    openSlash(mac, false);
  });
}

function submit(mac) {
  const textarea = mac.querySelector("textarea");
  const text = textarea.value.trim().replace(/^\/+/, "");
  closeSlash(mac);
  if (!text) return;
  const thread = mac.querySelector(".thread");
  if (thread && mac.dataset.scene === "session") {
    const block = el("div", "block user");
    block.innerHTML = `<span class="handle" aria-hidden="true"></span><p></p>`;
    block.querySelector("p").textContent = text;
    thread.append(block);
    requestAnimationFrame(() => block.classList.add("in"));
    const scroll = mac.querySelector(".scroll");
    if (scroll) scroll.scrollTop = scroll.scrollHeight;
  }
  textarea.value = "";
  textarea.style.height = "auto";
}

/* ————— 外壳 ————— */

function mount(which) {
  const host = hosts[which];
  const styleId = state[which];
  const mac = buildWindow(styleId, state.scene, state.appearance);
  host.replaceChildren(mac);
  bind(mac);
  if (state.scene === "session") play(mac);
  const cap = document.querySelector(`[data-win="${which}"] figcaption em`);
  if (cap) cap.textContent = byId(styleId).nameZh;
}

function mountAll() {
  mount("a");
  if (state.compare) mount("b");
}

function renderCards() {
  const root = document.querySelector(".pg-styles");
  root.replaceChildren();
  STRUCTURES.forEach((item, i) => {
    const card = el("button", "style-card");
    card.dataset.style = item.id;
    card.innerHTML = `
      <span class="sc-swatch" aria-hidden="true">
        <i style="background:${item.swatch[0]}"></i>
        <i style="background:${item.swatch[1]}"></i>
        <i style="background:${item.swatch[2]}"></i>
      </span>
      <span class="sc-body">
        <span class="sc-tag">${item.tag}</span>
        <strong>${i + 1} · ${item.nameZh}</strong>
        <small>${item.name}</small>
      </span>`;
    card.addEventListener("click", () => pick(item.id));
    root.append(card);
  });
  syncCards();
}

function syncCards() {
  const active = state[state.focus];
  document.querySelectorAll(".style-card").forEach((c) => c.classList.toggle("is-on", c.dataset.style === active));
}

function renderNotes() {
  const item = byId(state[state.focus]);
  document.querySelector(".pg-notes").innerHTML = `
    <p class="kicker">${item.tag}</p>
    <h2>${item.nameZh} <small>${item.name}</small></h2>
    <p class="lede">${item.thesis}</p>
    <dl>
      <div><dt>动效</dt><dd>${item.motion}</dd></div>
      <div><dt>代价</dt><dd>${item.cost}</dd></div>
      <div><dt>什么时候选它</dt><dd>${item.pick}</dd></div>
    </dl>`;
}

function pick(id) {
  state[state.focus] = id;
  mount(state.focus);
  syncCards();
  renderNotes();
  writeHash();
}

function setScene(scene) {
  state.scene = scene;
  document.querySelectorAll(".pg-scenes button").forEach((b) => b.classList.toggle("is-on", b.dataset.scene === scene));
  mountAll();
  writeHash();
}

function setAppearance(mode) {
  state.appearance = mode;
  document.querySelectorAll("[data-appearance]").forEach((b) => b.classList.toggle("is-on", b.dataset.appearance === mode));
  document.body.dataset.appearance = mode;
  mountAll();
  writeHash();
}

function toggleCompare() {
  state.compare = !state.compare;
  if (!state.compare) {
    state.focus = "a";
    document.querySelectorAll(".pg-frame").forEach((f) => f.classList.toggle("is-focus", f.dataset.win === "a"));
  }
  document.querySelector('[data-action="compare"]').setAttribute("aria-pressed", String(state.compare));
  document.querySelector(".pg-windows").dataset.compare = String(state.compare);
  document.querySelector('[data-win="b"]').hidden = !state.compare;
  if (state.compare) mount("b");
  syncCards();
  renderNotes();
  writeHash();
}

function writeHash() {
  const p = new URLSearchParams({ s: state.a, scene: state.scene, look: state.appearance });
  if (state.compare) {
    p.set("cmp", "1");
    p.set("b", state.b);
  }
  history.replaceState(null, "", `#${p}`);
}

function readHash() {
  const p = new URLSearchParams(location.hash.slice(1));
  const ids = STRUCTURES.map((s) => s.id);
  if (ids.includes(p.get("s"))) state.a = p.get("s");
  if (ids.includes(p.get("b"))) state.b = p.get("b");
  if (Object.keys(SCENES).includes(p.get("scene"))) state.scene = p.get("scene");
  if (["day", "dusk"].includes(p.get("look"))) state.appearance = p.get("look");
  if (p.get("cmp") === "1") state.compare = true;
}

document.querySelectorAll(".pg-scenes button").forEach((b) => b.addEventListener("click", () => setScene(b.dataset.scene)));
document.querySelectorAll("[data-appearance]").forEach((b) => b.addEventListener("click", () => setAppearance(b.dataset.appearance)));
document.querySelector('[data-action="compare"]').addEventListener("click", toggleCompare);
document.querySelector('[data-action="replay"]').addEventListener("click", () => {
  setScene("session");
});
document.querySelectorAll(".pg-frame").forEach((frame) => {
  frame.addEventListener("mousedown", () => {
    if (!state.compare) return;
    state.focus = frame.dataset.win;
    document.querySelectorAll(".pg-frame").forEach((f) => f.classList.toggle("is-focus", f === frame));
    syncCards();
    renderNotes();
  });
});

window.addEventListener("keydown", (e) => {
  const inField = ["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName);
  if (e.key === "Escape") document.querySelectorAll(".mac").forEach(closeSlash);
  if (inField) return;
  const n = Number(e.key);
  if (n >= 1 && n <= STRUCTURES.length) pick(STRUCTURES[n - 1].id);
  const scenes = { q: "session", w: "first", e: "empty", r: "error" };
  const k = e.key.toLowerCase();
  if (scenes[k]) setScene(scenes[k]);
  if (k === "c") toggleCompare();
  if (k === "d") setAppearance(state.appearance === "day" ? "dusk" : "day");
  if (e.code === "Space") {
    e.preventDefault();
    document.querySelectorAll(".mac").forEach((m) => m.dataset.scene === "session" && play(m));
  }
});

readHash();
document.body.dataset.appearance = state.appearance;
document.querySelectorAll("[data-appearance]").forEach((b) => b.classList.toggle("is-on", b.dataset.appearance === state.appearance));
document.querySelectorAll(".pg-scenes button").forEach((b) => b.classList.toggle("is-on", b.dataset.scene === state.scene));
document.querySelector('[data-action="compare"]').setAttribute("aria-pressed", String(state.compare));
document.querySelector(".pg-windows").dataset.compare = String(state.compare);
document.querySelector('[data-win="b"]').hidden = !state.compare;
renderCards();
mountAll();
renderNotes();
writeHash();
