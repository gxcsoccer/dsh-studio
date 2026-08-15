window.__ModuleLoader__.load({
	id: "dsh-studio",
	factory: (require) => {
var module = { exports: {} };
var exports = module.exports;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// packages/bundle/src/client.jsx
var client_exports = {};
__export(client_exports, {
  apply: () => apply,
  inject: () => inject
});
module.exports = __toCommonJS(client_exports);
var import_react2 = require("react");

// packages/bundle/src/wedged-session.jsx
var import_react = require("react");

// packages/bundle/src/diagnose.js
function diagnoseWedge(events) {
  const pending = /* @__PURE__ */ new Map();
  const settled = /* @__PURE__ */ new Set();
  let lastCleanTurnEnd;
  let orphanSeq;
  for (const entry of events) {
    const event = entry.event ?? entry;
    if (event.type === "tool/call") pending.set(event.data?.callId, event.seq);
    if (event.type === "tool/result") {
      settled.add(event.data?.message?.source?.callId ?? event.data?.callId);
    }
    if (event.type !== "turn/end") continue;
    const orphan = [...pending].find(([callId]) => !settled.has(callId));
    if (orphan) {
      if (orphanSeq === void 0) orphanSeq = orphan[1];
    } else if (orphanSeq === void 0) {
      lastCleanTurnEnd = event.seq;
    }
  }
  if (orphanSeq === void 0) return null;
  return { orphanSeq, anchor: lastCleanTurnEnd ?? null };
}

// packages/bundle/src/wedged-session.jsx
var import_jsx_runtime = require("react/jsx-runtime");
async function diagnose(api, sessionId) {
  const response = await api.sessions.history({ sessionId });
  if (!response?.result?.ok) return null;
  return diagnoseWedge(response.result.value.events);
}
function createWedgedSessionCard(ctx) {
  return function WedgedSessionCard({ useSession, sessionId }) {
    const lastFailureSeq = useSession((snapshot) => {
      const failures = snapshot.nodes.filter((node) => node.kind === "turn-error");
      return failures.length ? failures[failures.length - 1].seq : null;
    });
    const [diagnosis, setDiagnosis] = (0, import_react.useState)(null);
    const [recovering, setRecovering] = (0, import_react.useState)(false);
    (0, import_react.useEffect)(() => {
      if (lastFailureSeq === null) {
        setDiagnosis(null);
        return;
      }
      let abandoned = false;
      diagnose(ctx.connection.api, sessionId).then((result) => {
        if (!abandoned) setDiagnosis(result);
      });
      return () => {
        abandoned = true;
      };
    }, [lastFailureSeq, sessionId]);
    if (!diagnosis) return null;
    async function recover() {
      setRecovering(true);
      try {
        const child = await ctx.sessions.fork({ sessionId, atSeq: diagnosis.anchor });
        ctx.sessions.open(child);
      } finally {
        setRecovering(false);
      }
    }
    return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", { role: "status", style: styles.card, children: [
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)("div", { style: styles.title, children: "\u8FD9\u4E2A\u4F1A\u8BDD\u6CA1\u6CD5\u7EE7\u7EED\u4E86" }),
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", { style: styles.body, children: "\u6709\u4E00\u6B21\u5DE5\u5177\u8C03\u7528\u6CA1\u80FD\u7559\u4E0B\u7ED3\u679C\uFF0C\u800C\u4F1A\u8BDD\u65E5\u5FD7\u662F\u53EA\u80FD\u8FFD\u52A0\u7684\u3002\u4E4B\u540E\u6BCF\u4E00\u6761\u6D88\u606F\u90FD\u4F1A\u5E26\u4E0A\u90A3\u6B21\u6B8B\u7F3A\u7684\u8C03\u7528\uFF0C \u88AB\u6A21\u578B\u670D\u52A1\u7AEF\u62D2\u7EDD\u2014\u2014\u6240\u4EE5\u91CD\u8BD5\u4E00\u5B9A\u5931\u8D25\u3002" }),
      diagnosis.anchor === null ? /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", { style: styles.body, children: "\u8FD9\u4E2A\u4F1A\u8BDD\u7B2C\u4E00\u8F6E\u5C31\u4E2D\u65AD\u4E86\uFF0C\u6CA1\u6709\u53EF\u4EE5\u63A5\u7740\u8D70\u7684\u5E72\u51C0\u4F4D\u7F6E\u3002\u65B0\u5EFA\u4E00\u4E2A\u4F1A\u8BDD\u5427\u3002" }) : /* @__PURE__ */ (0, import_jsx_runtime.jsx)("button", { type: "button", onClick: recover, disabled: recovering, style: styles.action, children: recovering ? "\u6B63\u5728\u5206\u53C9\u2026" : "\u4ECE\u4E0A\u4E00\u8F6E\u5B8C\u597D\u7684\u5730\u65B9\u7EE7\u7EED" })
    ] });
  };
}
var styles = {
  card: {
    margin: "8px 0",
    padding: "12px 14px",
    borderRadius: 10,
    background: "var(--dsw-color-background-elevated, rgba(255,255,255,0.04))",
    border: "1px solid var(--dsw-color-border-default, rgba(255,255,255,0.12))",
    color: "var(--dsw-color-text-primary, inherit)",
    font: "13px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
  },
  title: { fontWeight: 600, marginBottom: 4 },
  body: { margin: "0 0 8px", color: "var(--dsw-color-text-secondary, inherit)" },
  action: {
    padding: "6px 12px",
    borderRadius: 7,
    border: "1px solid var(--dsw-color-border-default, rgba(255,255,255,0.16))",
    background: "var(--dsw-color-background-default, transparent)",
    color: "inherit",
    font: "inherit",
    cursor: "pointer"
  }
};

// packages/bundle/src/client.jsx
var import_jsx_runtime2 = require("react/jsx-runtime");
var inject = ["slots", "layout", "connection", "sessions"];
function apply(ctx) {
  const source = ctx.connection.hostDescription;
  function RuntimeConnectionBanner() {
    const description = (0, import_react2.useSyncExternalStore)(
      (onChange) => source.subscribe(onChange),
      () => source.getSnapshot(),
      () => void 0
    );
    if (description) return null;
    return /* @__PURE__ */ (0, import_jsx_runtime2.jsxs)("div", { role: "status", "aria-live": "polite", style: styles2.bar, children: [
      /* @__PURE__ */ (0, import_jsx_runtime2.jsx)("span", { style: styles2.dot, "aria-hidden": "true" }),
      /* @__PURE__ */ (0, import_jsx_runtime2.jsx)("span", { children: "\u4E0E\u8FD0\u884C\u65F6\u7684\u8FDE\u63A5\u65AD\u5F00\u4E86\uFF0C\u6B63\u5728\u91CD\u8FDE\u3002\u8FD9\u671F\u95F4\u53D1\u51FA\u7684\u6D88\u606F\u4E0D\u4F1A\u9001\u8FBE\u3002" })
    ] });
  }
  ctx.effect(
    () => ctx.slots.register(
      { name: "shell.overlay", id: "studio-connection", order: 100 },
      RuntimeConnectionBanner
    ),
    "studio: runtime connection banner"
  );
  ctx.slots.inject(
    "conversation.input.dock",
    () => ctx.slots.register(
      { name: "conversation.input.dock", id: "studio-wedged-session", order: 10 },
      createWedgedSessionCard(ctx)
    )
  );
}
var styles2 = {
  bar: {
    position: "absolute",
    top: 12,
    left: "50%",
    transform: "translateX(-50%)",
    zIndex: 40,
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "7px 14px",
    borderRadius: 8,
    // Follows the host theme rather than hardcoding colours: the tokens are
    // what `ui-theme` projects onto the document, so this tracks light/dark
    // without knowing which is active.
    background: "var(--dsw-color-background-elevated, #2b2b2b)",
    color: "var(--dsw-color-text-primary, #f5f5f5)",
    border: "1px solid var(--dsw-color-border-default, rgba(255,255,255,0.14))",
    boxShadow: "0 6px 20px rgba(0,0,0,0.18)",
    font: "13px/1.4 -apple-system, BlinkMacSystemFont, system-ui, sans-serif",
    pointerEvents: "none"
  },
  dot: {
    width: 7,
    height: 7,
    borderRadius: "50%",
    // Not colour alone: the sentence carries the meaning on its own.
    background: "var(--dsw-color-status-warning, #e0a030)",
    flex: "0 0 auto"
  }
};
return module.exports;
	}
});
