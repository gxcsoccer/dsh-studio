const STYLES = [
  {
    id: "current",
    name: "Current",
    nameZh: "当前",
    tag: "对照",
    swatches: ["#0B0B0C", "#D4A574", "#131316"],
    thesis: "现有 Studio Dark。语义 token 已经对，但还是工具壳：深底、细线、没有纸面和块。",
    motion: "线性淡出，120–200ms",
    pick: "只用来对照差距。不要把它当成目标气质。",
  },
  {
    id: "paper",
    name: "Paper",
    nameZh: "纸面",
    tag: "最像那一页",
    swatches: ["#f6f5f4", "#ffb110", "#0075de"],
    thesis: "暖纸、大标题、色块当标点。空状态像 Notion Dev 的句子，工具调用是坐在杏色上的代码卡。没有投影，没有玻璃。",
    motion: "200ms spring，标题里的动词药丸会轻弹一下",
    pick: "想让第一次打开就像 https://www.notion.com/zh-cn/product/dev。",
  },
  {
    id: "blocks",
    name: "Blocks",
    nameZh: "块",
    tag: "每天用",
    swatches: ["#ffffff", "#e6f3fe", "#111111"],
    thesis: "会话是一块块写出来的。悬停出句柄，/ 从输入处插入，工具是折叠 callout，检查器是页面属性。",
    motion: "块级 160ms；菜单从光标长出，不是屏幕中央的 HUD",
    pick: "要的是 Notion 工作区，不是营销页。适合长期待在里面写。",
  },
  {
    id: "stage",
    name: "Stage",
    nameZh: "舞台",
    tag: "开发者页",
    swatches: ["#f6f5f4", "#fff4d4", "#e6f3fe"],
    thesis: "左文书、右色块舞台。对话留在纸上；工具、代码、事件芯片在彩色面板里演——就是那页「Build any tool」的左右分栏。",
    motion: "舞台卡片贴着色块出现；事件芯片横排",
    pick: "最贴近 /product/dev 的版式：文案 + 活的代码窗。",
  },
  {
    id: "dusk",
    name: "Dusk",
    nameZh: "暮色",
    tag: "夜间纸",
    swatches: ["#1c1b19", "#e6c07b", "#6aa6ee"],
    thesis: "同一套纸面语法，换成暖炭。不是 OLED 玻璃，是关了灯的笔记本。药丸、代码卡、属性栏都还在。",
    motion: "与纸面相同",
    pick: "白天 Paper / Stage，晚上还要同一只手。",
  },
];

const state = {
  styleA: "paper",
  styleB: "stage",
  scene: "session",
  compare: false,
  focus: "a",
};

const hosts = {
  a: document.getElementById("host-a"),
  b: document.getElementById("host-b"),
};

function styleById(id) {
  return STYLES.find((item) => item.id === id) || STYLES[1];
}

function mountWindow(host, styleId) {
  const template = document.getElementById("mac-template");
  host.replaceChildren(template.content.cloneNode(true));
  const mac = host.querySelector(".mac");
  bindMac(mac);
  applyStyle(mac, styleId);
  applyScene(mac, state.scene);
  return mac;
}

function applyStyle(mac, styleId) {
  mac.dataset.style = styleId;
  const meta = styleById(styleId);
  mac.querySelectorAll(".theme-name").forEach((node) => {
    node.textContent = meta.nameZh;
  });
}

function applyScene(mac, scene) {
  mac.dataset.scene = scene;
}

function bindMac(mac) {
  const palette = mac.querySelector(".palette");
  const slashMenu = mac.querySelector(".slash-menu");
  const search = palette.querySelector("input");
  const textarea = mac.querySelector("textarea");

  mac.querySelectorAll("[data-open-palette]").forEach((el) => {
    el.addEventListener("click", () => openPalette(mac, true));
  });
  palette.addEventListener("click", (event) => {
    if (event.target === palette) openPalette(mac, false);
  });
  mac.querySelector(".send").addEventListener("click", () => sendDraft(mac));
  textarea.addEventListener("keydown", (event) => {
    if (event.key === "/" && textarea.value === "") {
      event.preventDefault();
      slashMenu.hidden = false;
      return;
    }
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      sendDraft(mac);
    }
    if (event.key === "Escape") slashMenu.hidden = true;
  });
  textarea.addEventListener("input", () => {
    if (!textarea.value.startsWith("/")) slashMenu.hidden = true;
  });
  slashMenu.querySelectorAll("button").forEach((btn) => {
    btn.addEventListener("click", () => {
      slashMenu.hidden = true;
      textarea.value = "";
      textarea.focus();
    });
  });
  search.addEventListener("input", () => filterPalette(mac, search.value));
}

function openPalette(mac, open) {
  const palette = mac.querySelector(".palette");
  palette.hidden = !open;
  if (open) {
    const input = palette.querySelector("input");
    input.value = "";
    filterPalette(mac, "");
    setTimeout(() => input.focus(), 20);
  }
}

function filterPalette(mac, query) {
  const q = query.trim().toLowerCase();
  mac.querySelectorAll(".palette-card li").forEach((item) => {
    const hit = !q || item.textContent.toLowerCase().includes(q);
    item.hidden = !hit;
  });
}

function sendDraft(mac) {
  const textarea = mac.querySelector("textarea");
  const text = textarea.value.trim();
  if (!text || text === "/") return;
  const thread = mac.querySelector(".thread");
  if (thread && state.scene === "session") {
    const block = document.createElement("div");
    block.className = "block user";
    block.innerHTML = `<span class="handle" aria-hidden="true"></span><p></p>`;
    block.querySelector("p").textContent = text;
    thread.appendChild(block);
    block.scrollIntoView({ block: "nearest" });
  }
  textarea.value = "";
  mac.querySelector(".slash-menu").hidden = true;
}

function renderStyleCards() {
  const root = document.querySelector(".pg-styles");
  root.replaceChildren();
  STYLES.forEach((item, index) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "style-card";
    btn.dataset.style = item.id;
    btn.innerHTML = `
      <div class="swatch" aria-hidden="true">
        <span style="background:${item.swatches[0]}"></span>
        <span style="background:${item.swatches[1]}"></span>
        <span style="background:${item.swatches[2]}"></span>
      </div>
      <div class="body">
        <span class="tag">${item.tag}</span>
        <strong>${index + 1} · ${item.nameZh}</strong>
        <small>${item.name}</small>
      </div>`;
    btn.addEventListener("click", () => selectStyle(item.id));
    root.appendChild(btn);
  });
  syncStyleCards();
}

function writeHash() {
  const params = new URLSearchParams();
  params.set("style", state.styleA);
  params.set("scene", state.scene);
  if (state.compare) {
    params.set("compare", "1");
    params.set("b", state.styleB);
  }
  history.replaceState(null, "", `#${params.toString()}`);
}

function readHash() {
  const params = new URLSearchParams(location.hash.replace(/^#/, ""));
  const style = params.get("style");
  const scene = params.get("scene");
  const b = params.get("b");
  if (STYLES.some((item) => item.id === style)) state.styleA = style;
  if (["session", "first", "empty", "error"].includes(scene || "")) state.scene = scene;
  if (params.get("compare") === "1") {
    state.compare = true;
    if (STYLES.some((item) => item.id === b)) state.styleB = b;
  }
}

function selectStyle(id) {
  if (state.focus === "b" && state.compare) state.styleB = id;
  else state.styleA = id;
  syncWindows();
  renderNotes();
  syncStyleCards();
  writeHash();
}

function syncStyleCards() {
  const active = state.focus === "b" && state.compare ? state.styleB : state.styleA;
  document.querySelectorAll(".style-card").forEach((card) => {
    card.classList.toggle("is-on", card.dataset.style === active);
  });
}

function syncWindows() {
  const macA = hosts.a.querySelector(".mac") || mountWindow(hosts.a, state.styleA);
  applyStyle(macA, state.styleA);
  applyScene(macA, state.scene);
  const frameB = document.querySelector('[data-win="b"]');
  const windows = document.querySelector(".pg-windows");
  windows.dataset.compare = String(state.compare);
  frameB.hidden = !state.compare;
  if (state.compare) {
    const macB = hosts.b.querySelector(".mac") || mountWindow(hosts.b, state.styleB);
    applyStyle(macB, state.styleB);
    applyScene(macB, state.scene);
  }
}

function renderNotes() {
  const id = state.focus === "b" && state.compare ? state.styleB : state.styleA;
  const item = styleById(id);
  document.querySelector(".pg-notes").innerHTML = `
    <p class="kicker">${item.tag}</p>
    <h2>${item.nameZh}</h2>
    <p>${item.thesis}</p>
    <dl>
      <div><dt>动效</dt><dd>${item.motion}</dd></div>
      <div><dt>什么时候选它</dt><dd>${item.pick}</dd></div>
    </dl>`;
}

function setScene(scene) {
  state.scene = scene;
  document.querySelectorAll(".pg-scenes [data-scene]").forEach((btn) => {
    btn.classList.toggle("is-on", btn.dataset.scene === scene);
  });
  document.querySelectorAll(".mac").forEach((mac) => applyScene(mac, scene));
  writeHash();
}

function toggleCompare() {
  state.compare = !state.compare;
  if (!state.compare) state.focus = "a";
  document.querySelector('[data-action="compare"]').setAttribute("aria-pressed", String(state.compare));
  syncWindows();
  syncStyleCards();
  renderNotes();
  writeHash();
}

function focusedMac() {
  const host = state.focus === "b" && state.compare ? hosts.b : hosts.a;
  return host.querySelector(".mac");
}

document.querySelectorAll(".pg-scenes [data-scene]").forEach((btn) => {
  btn.addEventListener("click", () => setScene(btn.dataset.scene));
});
document.querySelector('[data-action="compare"]').addEventListener("click", toggleCompare);
document.querySelectorAll(".pg-frame").forEach((frame) => {
  frame.addEventListener("click", () => {
    state.focus = frame.dataset.win;
    document.querySelectorAll(".pg-frame").forEach((node) => {
      node.classList.toggle("is-focus", node === frame);
    });
    syncStyleCards();
    renderNotes();
  });
});

window.addEventListener("keydown", (event) => {
  const inField = event.target instanceof HTMLElement && ["INPUT", "TEXTAREA"].includes(event.target.tagName);
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault();
    const mac = focusedMac();
    if (mac) openPalette(mac, true);
    return;
  }
  if (event.key === "Escape") {
    document.querySelectorAll(".mac").forEach((mac) => openPalette(mac, false));
    document.querySelectorAll(".slash-menu").forEach((menu) => {
      menu.hidden = true;
    });
    return;
  }
  if (inField) return;
  const styleKeys = ["1", "2", "3", "4", "5"];
  if (styleKeys.includes(event.key)) {
    selectStyle(STYLES[Number(event.key) - 1].id);
  }
  const scenes = { q: "session", w: "first", e: "empty", r: "error" };
  if (scenes[event.key.toLowerCase()]) setScene(scenes[event.key.toLowerCase()]);
  if (event.key.toLowerCase() === "c") toggleCompare();
  if (event.key === "/") {
    const mac = focusedMac();
    const textarea = mac?.querySelector("textarea");
    if (textarea && state.scene === "session") {
      event.preventDefault();
      textarea.focus();
      mac.querySelector(".slash-menu").hidden = false;
    }
  }
});

readHash();
renderStyleCards();
mountWindow(hosts.a, state.styleA);
setScene(state.scene);
document.querySelector('[data-action="compare"]').setAttribute("aria-pressed", String(state.compare));
syncWindows();
renderNotes();
writeHash();
