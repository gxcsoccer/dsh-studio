/**
 * The studio bundle's glue plugin.
 *
 * It exists for the same reason `dsh-web-app`'s runtime row exists: a couple of
 * values the patch needs are *workspace knowledge* — things only code that can
 * resolve packages knows. Writing them as YAML literals would hardcode
 * somebody's directory layout, so they are provided as an ordinary Cordis
 * service and the rows that need them inject it.
 *
 * ── Why this file imports nothing ───────────────────────────────────────────
 *
 * A bundle linked from a checkout does not resolve the profile's dependencies:
 * Node follows the symlink to its real path and searches upward from the
 * checkout. Installing our own copy of `@deepseek-ai/cordis` next to the
 * checkout would fix resolution and break something worse — Cordis identifies
 * services through module-local symbols, so a second copy means our
 * `extends Service` registers against a different symbol table than the running
 * kernel's, and the service silently never appears.
 *
 * So this plugin uses only the duck-typed seams: a plain `apply(ctx, config)`
 * and `ctx.provide(name, value)`, which registers an implementation and wakes
 * every fiber injecting it. Node builtins only.
 *
 * The cost is real and worth naming: no `Config` export means no Schemastery
 * validation, so `apply` validates by hand. That is a deliberate trade against
 * a duplicate-kernel bug that would be very hard to diagnose.
 */
import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'

export const name = 'studio-runtime'

const FRONTEND_INDEX = '@deepseek-ai/dsh-web-frontend/dist/index.html'

/** Loopback port for the browser surface. Pinned, never discovered from logs. */
const DEFAULT_PORT = 3099

export function apply(ctx, config = {}) {
  const port = config.port ?? DEFAULT_PORT
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`studio: port 必须是 1–65535 的整数，收到 ${JSON.stringify(config.port)}`)
  }

  ctx.provide('studioRuntime', {
    config: { port },
    distIndex: resolveFrontendIndex(ctx),
  })
}

/**
 * The official frontend's `index.html`, resolved from inside the Harness home
 * rather than from this file. Anchoring the lookup at `profiles/<any>/` lets
 * Node's own algorithm find it under either layout — a per-profile
 * `node_modules` or the hoisted one profiles share.
 */
function resolveFrontendIndex(ctx) {
  const dshHomePath = ctx.get('dshHomePath')
  if (!dshHomePath) {
    throw new Error('studio: dshHomePath 服务不存在 —— 这个 bundle 需要官方 app-boot 来组合')
  }

  const anchor = join(dshHomePath('profiles'), 'studio', 'package.json')
  try {
    const resolved = createRequire(anchor).resolve(FRONTEND_INDEX)
    if (existsSync(resolved)) return resolved
    throw new Error(`解析到 ${resolved} 但文件不存在`)
  } catch (error) {
    throw new Error(
      `studio: 找不到官方前端 dist（${FRONTEND_INDEX}）。\n` +
        `  从 ${anchor} 起解析：${error.message}\n` +
        `  这个 bundle 依赖 @deepseek-ai/dsh-web-frontend，确认它已装进 profile。`,
    )
  }
}
