/**
 * dsh-studio — out-of-tree Cordis bundle plugin.
 *
 * Published contract used (and nothing beyond it):
 *   - export apply(ctx, config)
 *   - export name, inject, Config (interface + schema)
 *   - ctx.effect() for the HTTP server lifetime
 *   - ctx.on('session/event', ...) best-effort
 *   - ctx.sessions if present (read-only presence / last-event memory)
 *
 * Does not vendor dsh, does not drive the agent loop.
 */

import { createServer } from "node:http";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

export const name = "dsh-studio";

/** Official inject is a string array of hard deps. sessions is probed. */
export const inject = ["agents"];


const DEFAULTS = {
  bridgePort: 43180,
  bindHost: "127.0.0.1",
  notifyOnTurnEnd: true,
  themeId: "system",
};




const FALLBACK_DARK = {
  background: "#0B0B0C",
  surface: "#131316",
  elevated: "#1A1A1F",
  text: { primary: "#EDEDEC", secondary: "#9B9A97", tertiary: "#6F6E69" },
  border: { subtle: "#232326", strong: "#3A3A40" },
  accent: "#D4A574",
  danger: "#E5484D",
  warning: "#F5A524",
  success: "#46A758",
  overlay: "rgba(0,0,0,0.52)",
  focusRing: "#D4A574",
  radius: { sm: 6, md: 10, lg: 14, xl: 20 },
  space: { "1": 4, "2": 8, "3": 12, "4": 16, "5": 24, "6": 32, "7": 40, "8": 56 },
  type: { xs: 11, sm: 12, md: 13, lg: 15, xl: 18, display: 28 },
  shadow: {
    sm: "0 1px 2px rgba(0,0,0,0.28)",
    md: "0 8px 24px rgba(0,0,0,0.36)",
    lg: "0 16px 48px rgba(0,0,0,0.40)",
  },
  motion: { fast: 120, normal: 200, slow: 320 },
};

const FALLBACK_LIGHT = {
  background: "#F7F6F3",
  surface: "#FFFFFF",
  elevated: "#FFFFFF",
  text: { primary: "#1C1C1A", secondary: "#6F6E69", tertiary: "#9B9A97" },
  border: { subtle: "#E8E6E1", strong: "#C9C7C0" },
  accent: "#B07D4F",
  danger: "#C62828",
  warning: "#B45309",
  success: "#1B7F4E",
  overlay: "rgba(20,18,14,0.40)",
  focusRing: "#B07D4F",
  radius: { sm: 6, md: 10, lg: 14, xl: 20 },
  space: { "1": 4, "2": 8, "3": 12, "4": 16, "5": 24, "6": 32, "7": 40, "8": 56 },
  type: { xs: 11, sm: 12, md: 13, lg: 15, xl: 18, display: 28 },
  shadow: {
    sm: "0 1px 2px rgba(28,28,26,0.06)",
    md: "0 8px 24px rgba(28,28,26,0.08)",
    lg: "0 16px 48px rgba(28,28,26,0.10)",
  },
  motion: { fast: 120, normal: 200, slow: 320 },
};

const EMBEDDED = {
  "studio-dark": {
    id: "studio-dark",
    name: "Studio Dark",
    nameZh: "Studio 深色",
    appearance: "dark",
    tokens: FALLBACK_DARK,
  },
  "studio-light": {
    id: "studio-light",
    name: "Studio Light",
    nameZh: "Studio 浅色",
    appearance: "light",
    tokens: FALLBACK_LIGHT,
  },
  system: {
    id: "system",
    name: "System",
    nameZh: "跟随系统",
    appearance: "system",
    light: FALLBACK_LIGHT,
    dark: FALLBACK_DARK,
  },
};

const state = {
  lastTurn: null,
  notifyOnTurnEnd: true,
  sessionsPresent: false,
  startedAt: new Date().toISOString(),
  themeId: DEFAULTS.themeId,
  bindHost: DEFAULTS.bindHost,
  appearanceHint: "dark",
  tokenOverride: null,
  packs: new Map(),
};

function pluginRoot() {
  try {
    return dirname(fileURLToPath(import.meta.url));
  } catch {
    return process.cwd();
  }
}

function themeSearchDirs() {
  const root = pluginRoot();
  return [
    join(root, "themes"),
    join(root, "plugin", "themes"),
    join(root, "..", "themes"),
  ];
}

function isRecord(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function asString(v, fallback) {
  return typeof v === "string" && v.length > 0 ? v : fallback;
}

function asScale(v, fallback) {
  if (!isRecord(v)) return { ...fallback };
  const out = {};
  for (const [k, val] of Object.entries(v)) {
    if (typeof val === "number" || typeof val === "string") out[k] = val;
  }
  return Object.keys(out).length ? out : { ...fallback };
}

function parseTokens(raw, fallback) {
  const v = isRecord(raw) ? raw : {};
  const text = isRecord(v.text) ? v.text : {};
  const border = isRecord(v.border) ? v.border : {};
  return {
    background: asString(v.background, fallback.background),
    surface: asString(v.surface, fallback.surface),
    elevated: asString(v.elevated, fallback.elevated),
    text: {
      primary: asString(text.primary, fallback.text.primary),
      secondary: asString(text.secondary, fallback.text.secondary),
      tertiary: asString(text.tertiary, fallback.text.tertiary),
    },
    border: {
      subtle: asString(border.subtle, fallback.border.subtle),
      strong: asString(border.strong, fallback.border.strong),
    },
    accent: asString(v.accent, fallback.accent),
    danger: asString(v.danger, fallback.danger),
    warning: asString(v.warning, fallback.warning),
    success: asString(v.success, fallback.success),
    overlay: asString(v.overlay, fallback.overlay),
    focusRing: asString(v.focusRing, fallback.focusRing),
    radius: asScale(v.radius, fallback.radius),
    space: asScale(v.space, fallback.space),
    type: asScale(v.type, fallback.type),
    shadow: asScale(v.shadow, fallback.shadow),
    motion: asScale(v.motion, fallback.motion),
  };
}

function parsePack(raw) {
  if (!isRecord(raw) || typeof raw.id !== "string") return null;
  const appearance =
    raw.appearance === "light" || raw.appearance === "dark" || raw.appearance === "system"
      ? raw.appearance
      : "dark";
  const pack = {
    id: raw.id,
    name: asString(raw.name, raw.id),
    nameZh: typeof raw.nameZh === "string" ? raw.nameZh : undefined,
    appearance,
  };
  if (appearance === "system") {
    pack.light = parseTokens(raw.light ?? raw.tokens, FALLBACK_LIGHT);
    pack.dark = parseTokens(raw.dark, FALLBACK_DARK);
  } else {
    pack.tokens = parseTokens(raw.tokens, appearance === "light" ? FALLBACK_LIGHT : FALLBACK_DARK);
  }
  return pack;
}

function loadPacksFromDisk() {
  const packs = new Map();
  for (const [id, pack] of Object.entries(EMBEDDED)) packs.set(id, pack);
  for (const dir of themeSearchDirs()) {
    if (!existsSync(dir)) continue;
    let names = [];
    try {
      names = readdirSync(dir).filter((n) => n.endsWith(".json"));
    } catch {
      continue;
    }
    for (const name of names) {
      try {
        const raw = JSON.parse(readFileSync(join(dir, name), "utf8"));
        const pack = parsePack(raw);
        if (pack) packs.set(pack.id, pack);
      } catch (err) {
        console.warn("[dsh-studio] skipped theme", name, err);
      }
    }
  }
  return packs;
}

function resolveTokens() {
  if (state.tokenOverride) {
    const pack = state.packs.get(state.themeId) ?? EMBEDDED[state.themeId] ?? EMBEDDED.system;
    return { pack, tokens: state.tokenOverride };
  }
  const pack = state.packs.get(state.themeId) ?? EMBEDDED[state.themeId] ?? EMBEDDED.system;
  if (pack.appearance === "system") {
    const tokens = state.appearanceHint === "light" ? (pack.light ?? FALLBACK_LIGHT) : (pack.dark ?? FALLBACK_DARK);
    return { pack, tokens };
  }
  return { pack, tokens: pack.tokens ?? FALLBACK_DARK };
}

export function tokensToCssVars(tokens) {
  const px = (v) => (typeof v === "number" ? `${v}px` : String(v));
  const ms = (v) => (typeof v === "number" ? `${v}ms` : String(v));
  const vars = {
    "--dsh-background": tokens.background,
    "--dsh-surface": tokens.surface,
    "--dsh-elevated": tokens.elevated,
    "--dsh-text-primary": tokens.text.primary,
    "--dsh-text-secondary": tokens.text.secondary,
    "--dsh-text-tertiary": tokens.text.tertiary,
    "--dsh-border-subtle": tokens.border.subtle,
    "--dsh-border-strong": tokens.border.strong,
    "--dsh-accent": tokens.accent,
    "--dsh-danger": tokens.danger,
    "--dsh-warning": tokens.warning,
    "--dsh-success": tokens.success,
    "--dsh-overlay": tokens.overlay,
    "--dsh-focus-ring": tokens.focusRing,
  };
  for (const [k, v] of Object.entries(tokens.radius)) vars[`--dsh-radius-${k}`] = px(v);
  for (const [k, v] of Object.entries(tokens.space)) vars[`--dsh-space-${k}`] = px(v);
  for (const [k, v] of Object.entries(tokens.type)) vars[`--dsh-type-${k}`] = px(v);
  for (const [k, v] of Object.entries(tokens.shadow)) vars[`--dsh-shadow-${k}`] = String(v);
  for (const [k, v] of Object.entries(tokens.motion)) vars[`--dsh-motion-${k}`] = ms(v);
  return vars;
}

export function cssVariablesStylesheet(tokens) {
  const vars = tokensToCssVars(tokens);
  const body = Object.entries(vars)
    .map(([k, v]) => `  ${k}: ${v};`)
    .join("\n");
  return `:root, :host, html, body {\n${body}\n}\n`;
}

function trySchemastery() {
  try {
    const require = createRequire(import.meta.url);
    const mod = require("@deepseek-ai/schemastery");
    const Schema = (mod && typeof mod === "object" && "default" in mod) ? mod.default : mod;
    if (Schema && typeof Schema.object === "function") {
      return Schema;
    }
  } catch {
    // Peer is not resolvable from this checkout. That is expected.
  }
  return null;
}

function configIssues(raw) {
  if (raw == null) return [];
  if (!isRecord(raw)) return [{ message: "config must be an object" }];
  const issues = [];
  if ("bridgePort" in raw) {
    const port = raw.bridgePort;
    if (typeof port !== "number" || !Number.isFinite(port) || port <= 0 || port >= 65536) {
      issues.push({ message: "$.bridgePort expected a port number (1-65535)" });
    }
  }
  if ("bindHost" in raw && typeof raw.bindHost !== "string") {
    issues.push({ message: "$.bindHost expected string" });
  }
  if ("notifyOnTurnEnd" in raw && typeof raw.notifyOnTurnEnd !== "boolean") {
    issues.push({ message: "$.notifyOnTurnEnd expected boolean" });
  }
  if ("themeId" in raw && typeof raw.themeId !== "string") {
    issues.push({ message: "$.themeId expected string" });
  }
  return issues;
}

/**
 * Standard Schema v1 fallback. Cordis accepts any Standard Schema validator;
 * a plain config object is not enough (official docs).
 */
function standardSchemaConfig() {
  return {
    "~standard": {
      version: 1,
      vendor: "dsh-studio",
      validate(value) {
        const issues = configIssues(value);
        if (issues.length) return { issues };
        return { value: normalizeConfig(value) };
      },
    },
  };
}

function buildConfigSchema() {
  const Schema = trySchemastery();
  if (!Schema) return standardSchemaConfig();
  return Schema.object({
    bridgePort: Schema.number().default(DEFAULTS.bridgePort),
    bindHost: Schema.string().default(DEFAULTS.bindHost),
    notifyOnTurnEnd: Schema.boolean().default(DEFAULTS.notifyOnTurnEnd),
    themeId: Schema.string().default(DEFAULTS.themeId),
  });
}

export const Config = buildConfigSchema();

function normalizeConfig(raw) {
  const v = isRecord(raw) ? raw : {};
  const port = v.bridgePort;
  const host = v.bindHost;
  const themeId = v.themeId;
  return {
    bridgePort:
      typeof port === "number" && Number.isFinite(port) && port > 0 && port < 65536
        ? Math.floor(port)
        : DEFAULTS.bridgePort,
    bindHost: typeof host === "string" && host.length > 0 ? host : DEFAULTS.bindHost,
    notifyOnTurnEnd:
      typeof v.notifyOnTurnEnd === "boolean" ? v.notifyOnTurnEnd : DEFAULTS.notifyOnTurnEnd,
    themeId: typeof themeId === "string" && themeId.length > 0 ? themeId : DEFAULTS.themeId,
  };
}

function eventType(event) {
  if (!isRecord(event)) return "";
  if (typeof event.type === "string") return event.type;
  if (typeof event.kind === "string") return event.kind;
  return "";
}

function pickTitle(session, event) {
  const from = (obj, keys) => {
    if (!isRecord(obj)) return undefined;
    for (const key of keys) {
      const val = obj[key];
      if (typeof val === "string" && val.trim()) return val.trim();
    }
    if (isRecord(obj.data)) {
      for (const key of keys) {
        const val = obj.data[key];
        if (typeof val === "string" && val.trim()) return val.trim();
      }
    }
    return undefined;
  };
  return (
    from(event, ["title", "name"]) ??
    from(session, ["title", "name", "id", "sessionId"]) ??
    "DSH Studio"
  );
}

function pickSessionId(session, event) {
  const from = (obj) => {
    if (!isRecord(obj)) return undefined;
    for (const key of ["id", "sessionId"]) {
      const val = obj[key];
      if (typeof val === "string" && val) return val;
    }
    return undefined;
  };
  return from(session) ?? from(event);
}

function isTurnEnd(type) {
  return type === "turn/end" || type.endsWith("/turn/end") || type === "turn-end";
}

function rememberEvent(session, event) {
  const type = eventType(event);
  if (!type) return;
  if (isTurnEnd(type) || type === "turn/start" || type.endsWith("/turn/start")) {
    state.lastTurn = {
      type,
      at: new Date().toISOString(),
      title: pickTitle(session, event),
      sessionId: pickSessionId(session, event),
    };
  }
}

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c)));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function themePayload() {
  const { pack, tokens } = resolveTokens();
  return {
    ok: true,
    themeId: pack.id,
    name: pack.name,
    nameZh: pack.nameZh,
    appearance: pack.appearance,
    appearanceHint: state.appearanceHint,
    tokens,
    cssVariables: tokensToCssVars(tokens),
    stylesheet: cssVariablesStylesheet(tokens),
    packs: [...state.packs.values()].map((p) => ({
      id: p.id,
      name: p.name,
      nameZh: p.nameZh,
      appearance: p.appearance,
    })),
  };
}

async function handleRequest(req, res) {
  const host = req.headers.host ?? "";
  const url = new URL(req.url ?? "/", `http://${host || "127.0.0.1"}`);
  const method = (req.method ?? "GET").toUpperCase();

  if (method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type",
    });
    res.end();
    return;
  }

  if (url.pathname === "/health" && method === "GET") {
    json(res, 200, { ok: true, profile: "studio", name });
    return;
  }

  if (url.pathname === "/status" && method === "GET") {
    json(res, 200, {
      ok: true,
      profile: "studio",
      name,
      sessions: state.sessionsPresent,
      notifyOnTurnEnd: state.notifyOnTurnEnd,
      startedAt: state.startedAt,
      lastTurn: state.lastTurn,
      themeId: state.themeId,
      bindHost: state.bindHost,
    });
    return;
  }

  if (url.pathname === "/theme" && method === "GET") {
    json(res, 200, themePayload());
    return;
  }

  if (url.pathname === "/theme" && method === "POST") {
    const raw = await readBody(req);
    let body = {};
    if (raw.trim()) {
      try {
        const parsed = JSON.parse(raw);
        if (!isRecord(parsed)) {
          json(res, 400, { ok: false, error: "body_must_be_object" });
          return;
        }
        body = parsed;
      } catch {
        json(res, 400, { ok: false, error: "invalid_json" });
        return;
      }
    }
    if (typeof body.themeId === "string" && body.themeId) {
      if (!state.packs.has(body.themeId) && !EMBEDDED[body.themeId]) {
        json(res, 404, { ok: false, error: "unknown_theme", themeId: body.themeId });
        return;
      }
      state.themeId = body.themeId;
      state.tokenOverride = null;
    }
    if (body.appearance === "light" || body.appearance === "dark") {
      state.appearanceHint = body.appearance;
    }
    if (isRecord(body.tokens)) {
      const base = resolveTokens().tokens;
      state.tokenOverride = parseTokens(body.tokens, base);
    }
    json(res, 200, themePayload());
    return;
  }

  if (url.pathname === "/notify-test" && method === "POST") {
    await readBody(req).catch(() => "");
    state.lastTurn = {
      type: "turn/end",
      at: new Date().toISOString(),
      title: "notify-test",
    };
    json(res, 200, { ok: true, lastTurn: state.lastTurn });
    return;
  }

  json(res, 404, { ok: false, error: "not_found" });
}

export function startBridge(config) {
  const server = createServer((req, res) => {
    void handleRequest(req, res).catch((err) => {
      const message = err instanceof Error ? err.message : String(err);
      if (!res.headersSent) json(res, 500, { ok: false, error: message });
      else res.end();
    });
  });

  server.on("error", (err) => {
    console.error("[dsh-studio] bridge server error:", err);
  });

  server.listen(config.bridgePort, config.bindHost, () => {
    console.log(
      `[dsh-studio] bridge listening on http://${config.bindHost}:${config.bridgePort}`,
    );
  });

  return {
    close() {
      return new Promise((resolve) => {
        server.close(() => resolve());
        // Unref so unload cannot hang the process if a socket lingers.
        server.unref();
      });
    },
  };
}

function wireSessionEvents(ctx) {
  state.sessionsPresent = ctx.sessions != null;
  if (typeof ctx.on !== "function") return;

  const handler = (...args) => {
    // Documented cookbook shape: (session, event)
    const session = args.length >= 2 ? args[0] : undefined;
    const event = args.length >= 2 ? args[1] : args[0];
    try {
      rememberEvent(session, event);
    } catch (err) {
      console.warn("[dsh-studio] session/event handler error:", err);
    }
  };

  try {
    ctx.on("session/event", handler);
  } catch (err) {
    console.warn("[dsh-studio] ctx.on('session/event') failed:", err);
  }
}

export function apply(ctx, config) {
  const resolved = normalizeConfig(config);
  state.notifyOnTurnEnd = resolved.notifyOnTurnEnd;
  state.startedAt = new Date().toISOString();
  state.lastTurn = null;
  state.themeId = resolved.themeId;
  state.bindHost = resolved.bindHost;
  state.tokenOverride = null;
  state.packs = loadPacksFromDisk();

  console.log("[dsh-studio] plugin loaded");

  const start = () => {
    const bridge = startBridge(resolved);
    return () => {
      void bridge.close();
    };
  };

  if (typeof ctx?.effect === "function") {
    ctx.effect(start);
  } else {
    start();
  }

  try {
    wireSessionEvents(ctx ?? {});
  } catch (err) {
    console.warn("[dsh-studio] session wiring skipped:", err);
  }
}

function isDirectRun() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return import.meta.url === pathToFileURL(entry).href;
  } catch {
    return false;
  }
}

if (isDirectRun()) {
  const fakeCtx = {
    on() {
      return undefined;
    },
    effect(factory) {
      const dispose = factory();
      const stop = () => {
        if (typeof dispose === "function") dispose();
        process.exit(0);
      };
      process.on("SIGINT", stop);
      process.on("SIGTERM", stop);
    },
  };
  apply(fakeCtx, DEFAULTS);
  console.log("[dsh-studio] standalone bridge (no dsh). Ctrl+C to stop.");
}
