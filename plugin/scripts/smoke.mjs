#!/usr/bin/env node
import { createServer } from "node:http";
import { apply, startBridge } from "../index.js";

const port = 43181;
const bindHost = "127.0.0.1";
let disposed = false;

const ctx = {
  sessions: { present: true },
  on(event, handler) {
    if (event === "session/event") {
      handler({ id: "s1", title: "smoke" }, { type: "turn/end" });
    }
  },
  effect(factory) {
    const dispose = factory();
    return () => {
      disposed = true;
      if (typeof dispose === "function") dispose();
    };
  },
};

apply(ctx, { bridgePort: port, bindHost, notifyOnTurnEnd: true, themeId: "studio-dark" });

const base = `http://${bindHost}:${port}`;

async function get(path) {
  const res = await fetch(base + path);
  const body = await res.json();
  return { status: res.status, body };
}

async function post(path, body) {
  const res = await fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: body ? JSON.stringify(body) : "",
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

const health = await get("/health");
if (health.status !== 200 || health.body.ok !== true || health.body.profile !== "studio") {
  throw new Error("GET /health failed: " + JSON.stringify(health));
}

const status = await get("/status");
if (status.status !== 200 || !status.body.lastTurn || status.body.lastTurn.type !== "turn/end") {
  throw new Error("GET /status failed: " + JSON.stringify(status));
}

const theme = await get("/theme");
if (theme.status !== 200 || !theme.body.tokens?.background || !theme.body.cssVariables["--dsh-accent"]) {
  throw new Error("GET /theme failed: " + JSON.stringify(theme));
}

const swapped = await post("/theme", { themeId: "studio-light" });
if (swapped.status !== 200 || swapped.body.themeId !== "studio-light") {
  throw new Error("POST /theme failed: " + JSON.stringify(swapped));
}

const notify = await post("/notify-test");
if (notify.status !== 200 || notify.body.ok !== true) {
  throw new Error("POST /notify-test failed: " + JSON.stringify(notify));
}

const missing = await get("/nope");
if (missing.status !== 404) {
  throw new Error("404 expected");
}

// Direct startBridge close path
const extra = startBridge({ bridgePort: 43182, bindHost, notifyOnTurnEnd: true, themeId: "system" });
await extra.close();

console.log("[dsh-studio] smoke ok");
process.exit(0);
