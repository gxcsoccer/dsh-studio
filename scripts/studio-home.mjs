/**
 * Materialize the `studio` dsh profile into a runnable `$DSH_HOME`, and
 * (optionally) launch the official `dsh` launcher against it.
 *
 * WHY THIS SCRIPT EXISTS
 * ----------------------
 * A dsh profile is not a directory in a repository: it is a directory under
 * `$DSH_HOME/profiles/<name>`, with `package.json` (its `dsh.profile.bundles`
 * layer list) and `cordis.patch.yml` (the user patch layer applied over every
 * bundle layer). `profiles/studio/` here is the *source* of that directory —
 * versioned, reviewable, diffable — and this script is what puts a copy of it
 * where the launcher looks, together with the two Studio plugins.
 *
 * The plugins are installed as **real copies of their built output**, not as
 * symlinks into this repository, and that is deliberate. A symlink would make
 * Node resolve their `@deepseek-ai/*` imports from this repo's own
 * `node_modules`, i.e. a *second* copy of cordis and the host packages, in a
 * process that already runs the launcher's copies. Two cordis instances share
 * no services: the row would activate and then fail to see `apiProxy`. Copied
 * into the profile's `node_modules`, the ordinary parent-directory walk finds
 * the launcher's own packages through the `$DSH_HOME/profiles/node_modules`
 * fallback dsh maintains — one cordis, one gateway, one set of services.
 *
 * Usage:
 *   node scripts/studio-home.mjs                 # materialize, print, exit
 *   node scripts/studio-home.mjs --run --dump-config
 *   node scripts/studio-home.mjs --run           # boot the profile
 *   node scripts/studio-home.mjs --run -- --port 3081
 *
 * Environment:
 *   DSH_HOME   the harness home to materialize into (default `<repo>/.dsh-home`)
 *   DSH_CLI    path of an installed `@deepseek-ai/dsh` bin (default: npx)
 */

import { spawn } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Repository root (this file lives in `<root>/scripts`). */
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

/** Profile name; also the directory name under `profiles/` and under `$DSH_HOME/profiles/`. */
const PROFILE = 'studio'

/** The dsh release this profile is composed against. */
const DSH_VERSION = '0.1.0-rc.6'

/** Files of the versioned profile source that are copied verbatim. */
const PROFILE_FILES = ['package.json', 'cordis.patch.yml', 'cordis.yml']

/** The Studio plugins the profile's rows name, by package directory. */
const PLUGINS = [
  { dir: 'packages/studio-surface', name: '@dsh-studio/studio-surface' },
  { dir: 'packages/studio-client', name: '@dsh-studio/studio-client' },
]

/**
 * Copy one built plugin package into the profile's `node_modules`.
 * @param {string} profileDir - absolute profile directory under `$DSH_HOME`.
 * @param {{ dir: string, name: string }} plugin - repo-relative directory and package name.
 * @returns {string[]} the file names installed under the package's `lib/`.
 */
function installPlugin(profileDir, plugin) {
  const source = join(ROOT, plugin.dir)
  const lib = join(source, 'lib')
  if (!existsSync(join(lib, 'index.js'))) {
    throw new Error(`${plugin.name}: lib/index.js is missing — run \`npm run bundle\` first`)
  }
  const target = join(profileDir, 'node_modules', ...plugin.name.split('/'))
  mkdirSync(dirname(target), { recursive: true })
  // Manifest plus built output only: `src/` and `tests/` are not what a
  // profile runs, and `node_modules/` must NOT come along (that is the second
  // cordis this script exists to avoid).
  cpSync(join(source, 'package.json'), join(target, 'package.json'))
  cpSync(lib, join(target, 'lib'), { recursive: true })
  return readdirSync(join(target, 'lib')).sort()
}

/**
 * Materialize the profile.
 * @returns {{ home: string, profileDir: string }} the home and profile directories.
 */
function materialize() {
  const home = resolve(process.env.DSH_HOME ?? join(ROOT, '.dsh-home'))
  const profileDir = join(home, 'profiles', PROFILE)
  mkdirSync(profileDir, { recursive: true })
  for (const file of PROFILE_FILES) {
    cpSync(join(ROOT, 'profiles', PROFILE, file), join(profileDir, file))
  }
  for (const plugin of PLUGINS) {
    const files = installPlugin(profileDir, plugin)
    process.stdout.write(`installed ${plugin.name} (lib/: ${files.join(', ')})\n`)
  }
  process.stdout.write(`DSH_HOME=${home}\nprofile=${profileDir}\n`)
  return { home, profileDir }
}

/**
 * Launch the official launcher against the materialized home.
 * @param {string} home - the harness home.
 * @param {string[]} args - launcher arguments after `--profile studio`.
 * @returns {Promise<number>} the child's exit code.
 */
function run(home, args) {
  const cli = process.env.DSH_CLI
  const command = cli === undefined ? 'npx' : process.execPath
  const argv = cli === undefined
    ? ['-y', `@deepseek-ai/dsh@${DSH_VERSION}`, '--profile', PROFILE, ...args]
    : [cli, '--profile', PROFILE, ...args]
  process.stdout.write(`$ DSH_HOME=${home} ${command} ${argv.join(' ')}\n`)
  const child = spawn(command, argv, {
    cwd: ROOT,
    env: { ...process.env, DSH_HOME: home },
    stdio: 'inherit',
  })
  return new Promise(resolvePromise => {
    child.on('exit', code => resolvePromise(code ?? 1))
  })
}

const args = process.argv.slice(2)
const runIndex = args.indexOf('--run')
const { home } = materialize()
if (runIndex !== -1) {
  // Everything after `--run` belongs to the launcher; a bare `--` separator
  // (npm inserts one for `npm run studio:web -- --port 3081`) is dropped.
  const forwarded = args.slice(runIndex + 1).filter(argument => argument !== '--')
  process.exit(await run(home, forwarded))
}
