/**
 * Resolves the official contract off the machine's own Harness profile rather
 * than a second copy in this repo: codegen must run against the exact
 * `@deepseek-ai/dsh-host-apiproxy` the profile boots, or the generated Swift
 * describes a runtime nobody is running.
 */
import { createRequire } from 'node:module'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { homedir } from 'node:os'

export const APIPROXY = '@deepseek-ai/dsh-host-apiproxy'

export function defaultModulesDir() {
  const home = process.env.DSH_HOME ?? join(homedir(), '.dsh')
  return join(home, 'profiles', 'node_modules')
}

export function openContract(modulesDir = defaultModulesDir()) {
  const pkgDir = join(modulesDir, APIPROXY)
  let manifest
  try {
    manifest = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8'))
  } catch {
    throw new Error(
      `找不到 ${APIPROXY}，查找路径 ${pkgDir}\n` +
        `codegen 需要一个已安装的 harness profile。先跑一次官方 dsh，或用 --from 指定 node_modules 目录。`,
    )
  }

  const require = createRequire(join(pkgDir, 'package.json'))
  const apiDir = join(pkgDir, 'lib', 'types', 'api')

  return {
    version: manifest.version,
    pkgDir,
    apiDir,
    async zod() {
      return import(pathToFileURL(require.resolve('zod')).href)
    },
    /** Every `<domain>.schema.js` module, keyed by domain. */
    async schemaModules() {
      const entries = readdirSync(apiDir)
        .filter((f) => f.endsWith('.schema.js'))
        .sort()
      const out = new Map()
      for (const file of entries) {
        const mod = await import(pathToFileURL(join(apiDir, file)).href)
        out.set(file.replace(/\.schema\.js$/, ''), mod)
      }
      return out
    },
    /**
     * Wire method names, read straight out of `rpc-map.d.ts`. The map is the
     * contract's own list; deriving it from schema exports instead would make a
     * missing schema look like a missing method.
     */
    methodKeys() {
      const src = readFileSync(join(apiDir, 'rpc-map.d.ts'), 'utf8')
      const body = src.slice(src.indexOf('interface RpcMethodMap'))
      return [...body.matchAll(/^\s*'([a-zA-Z]+\.[a-zA-Z]+)':/gm)].map((m) => m[1])
    },
  }
}

/** `session.list` → `sessionList`, the stem both schema exports are named after. */
export const methodStem = (method) => method.replace(/\.(.)/, (_, c) => c.toUpperCase())
