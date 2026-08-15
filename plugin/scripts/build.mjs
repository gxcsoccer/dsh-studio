#!/usr/bin/env node
/**
 * Self-contained prepare/build. Transpiles src/index.ts -> index.js.
 * No monorepo project references. Uses local esbuild when present.
 */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const entry = join(root, "src/index.ts");
const outfile = join(root, "index.js");

function runEsbuild(bin, args) {
  const result = spawnSync(bin, args, { cwd: root, stdio: "inherit" });
  return result.status === 0;
}

const args = [
  entry,
  "--outfile=" + outfile,
  "--format=esm",
  "--platform=node",
  "--target=node22",
  "--bundle=false",
  "--log-level=warning",
];

let ok = false;
try {
  const require = createRequire(import.meta.url);
  const esbuildBin = require.resolve("esbuild/bin/esbuild");
  ok = runEsbuild(process.execPath, [esbuildBin, ...args]);
} catch {
  ok = false;
}

if (!ok) {
  const npx = spawnSync("npx", ["--yes", "esbuild", ...args], {
    cwd: root,
    stdio: "inherit",
  });
  ok = npx.status === 0;
}

if (!ok) {
  if (existsSync(outfile)) {
    console.warn("[dsh-studio] esbuild unavailable; keeping existing index.js (prebuilt).");
    process.exit(0);
  }
  console.error("[dsh-studio] build failed and no prebuilt index.js is present.");
  process.exit(1);
}

console.log("[dsh-studio] wrote index.js");
