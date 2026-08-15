#!/usr/bin/env node
/**
 * Provisions the `studio` profile from the bundle's own dependency list.
 *
 * Why this exists: a bundle added by local path arrives over pnpm's `link:`
 * protocol, and pnpm does not install a linked package's dependencies into the
 * linking project. Published from a registry the dependency list would carry
 * itself; linked from a checkout it does not, so the missing part of the list is
 * replayed into the profile here.
 *
 * ── Why it installs as little as possible ───────────────────────────────────
 *
 * Packages resolve from two places: the dsh installation's shared
 * `$DSH_HOME/profiles/node_modules`, and the profile's own. Installing into the
 * profile something the installation already ships produces a SECOND COPY of
 * that module — and several harness packages key internal lookups on
 * module-local `Symbol()`s. Two copies of `@deepseek-ai/dsh-tools` means
 * `dsh-agent-loop` reads `ctx.tools[schedulerSymbol]` with a symbol from one
 * copy while the registry was built by the other, gets `undefined`, and every
 * tool call dies with `Cannot read properties of undefined (reading 'prepare')`
 * — no missing-module error, nothing pointing at packaging.
 *
 * So the shared set is treated as authoritative and only genuine gaps are
 * installed.
 *
 *   node tools/provision-profile/provision.mjs [--profile studio] [--dry-run]
 *                                             [--registry <url>]
 *
 * `--registry` is forwarded to pnpm untouched. Reach for it when the configured
 * registry is a private mirror that either does not carry `@deepseek-ai/*` or is
 * only reachable on a VPN — the failure looks like ECONNRESET or a TLS error
 * partway through the install, not like a missing package.
 */
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..', '..')
const bundleDir = join(repo, 'packages', 'bundle')

const args = process.argv.slice(2)
const argOf = (flag, fallback) => {
  const index = args.indexOf(flag)
  return index === -1 ? fallback : args[index + 1]
}
const profile = argOf('--profile', 'studio')
const dryRun = args.includes('--dry-run')
const registry = argOf('--registry', undefined)
const pnpmFlags = registry ? [`--registry=${registry}`] : []

const dshHome = process.env.DSH_HOME ?? join(homedir(), '.dsh')
const launcher = findLauncher()

const manifest = JSON.parse(readFileSync(join(bundleDir, 'package.json'), 'utf8'))
const declared = Object.entries(manifest.dependencies ?? {})

const sharedRoot = join(dshHome, 'profiles', 'node_modules')
const shipped = declared.filter(([name]) => existsSync(join(sharedRoot, name)))
const gaps = declared.filter(([name]) => !existsSync(join(sharedRoot, name)))

console.log(`profile       ${profile}`)
console.log(`launcher      ${launcher.join(' ')}`)
console.log(`roster 声明    ${declared.length} 个`)
console.log(`dsh 已自带     ${shipped.length} 个（不重装 —— 重装会造出第二份模块实例）`)
console.log(`需要补装       ${gaps.length} 个`)

if (dryRun) {
  console.log('\n--dry-run，只打印不执行。')
  for (const [name, range] of gaps) console.log('  补装 ' + name + '@' + range)
  process.exit(0)
}

// The bundle link first: this creates the profile and puts `dsh-studio` into
// `dsh.profile.bundles`. Gap packages follow as plain dependencies — they
// declare no `dsh.bundle`, so the reconciler correctly leaves them out of the
// layer list.
run(['plugin', '--profile', profile, 'add', ...pnpmFlags, bundleDir])
if (gaps.length) {
  run(['plugin', '--profile', profile, 'add', ...pnpmFlags, ...gaps.map(([n, r]) => `${n}@${r}`)])
}

const composed = JSON.parse(readFileSync(join(dshHome, 'profiles', profile, 'package.json'), 'utf8'))
console.log(`\nbundles       ${composed.dsh.profile.bundles.join(' → ')}`)

const profileRoot = join(dshHome, 'profiles', profile, 'node_modules')
const unresolvable = declared
  .map(([name]) => name)
  .filter((name) => !existsSync(join(profileRoot, name)) && !existsSync(join(sharedRoot, name)))
if (unresolvable.length) {
  console.error(`\n以下包解析不到，profile 不可用：\n  ${unresolvable.join('\n  ')}`)
  process.exit(1)
}

// The check that would have caught the duplicate: a package present in BOTH
// roots is loaded twice, and the symptom shows up far from here.
const duplicated = declared
  .map(([name]) => name)
  .filter((name) => existsSync(join(profileRoot, name)) && existsSync(join(sharedRoot, name)))
if (duplicated.length) {
  console.error(
    `\n同一个包同时存在于 profile 与 dsh 安装两处，会被加载两份：\n  ${duplicated.join('\n  ')}\n\n` +
      `症状不会指向这里 —— 典型表现是任何工具调用都报 ` +
      `"Cannot read properties of undefined (reading 'prepare')"。\n` +
      `处理：删掉 ${profileRoot} 下的重复项，让它们从 dsh 安装解析。`,
  )
  process.exit(1)
}

console.log('roster        全部可解析，且无重复副本')
console.log(`\n下一步： node <dsh> --profile ${profile} --dump-config`)

function run(argv) {
  console.log(`\n$ dsh ${argv.join(' ').slice(0, 120)}${argv.join(' ').length > 120 ? ' …' : ''}`)
  execFileSync(launcher[0], [...launcher.slice(1), ...argv], { stdio: 'inherit', cwd: repo })
}

/**
 * Same order the desktop host uses: the profile's own copy first (version
 * aligned, no network), then PATH, then npx.
 */
function findLauncher() {
  const binJS = join(dshHome, 'profiles', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
  if (existsSync(binJS)) return [process.execPath, binJS]
  for (const dir of (process.env.PATH ?? '').split(':')) {
    if (dir && existsSync(join(dir, 'dsh'))) return [join(dir, 'dsh')]
  }
  return ['npx', '--yes', '@deepseek-ai/dsh']
}
