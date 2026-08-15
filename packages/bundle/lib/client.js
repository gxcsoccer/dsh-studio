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

// src/client.jsx
var client_exports = {};
__export(client_exports, {
  apply: () => apply,
  inject: () => inject
});
module.exports = __toCommonJS(client_exports);
var import_react = require("react");
var import_jsx_runtime = require("react/jsx-runtime");
var inject = ["slots", "layout", "connection"];
function apply(ctx) {
  const source = ctx.connection.hostDescription;
  function RuntimeConnectionBanner() {
    const description = (0, import_react.useSyncExternalStore)(
      (onChange) => source.subscribe(onChange),
      () => source.getSnapshot(),
      () => void 0
    );
    if (description) return null;
    return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", { role: "status", "aria-live": "polite", style: styles.bar, children: [
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", { style: styles.dot, "aria-hidden": "true" }),
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", { children: "\u4E0E\u8FD0\u884C\u65F6\u7684\u8FDE\u63A5\u65AD\u5F00\u4E86\uFF0C\u6B63\u5728\u91CD\u8FDE\u3002\u8FD9\u671F\u95F4\u53D1\u51FA\u7684\u6D88\u606F\u4E0D\u4F1A\u9001\u8FBE\u3002" })
    ] });
  }
  ctx.effect(
    () => ctx.slots.register(
      { name: "shell.overlay", id: "studio-connection", order: 100 },
      RuntimeConnectionBanner
    ),
    "studio: runtime connection banner"
  );
}
var styles = {
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
