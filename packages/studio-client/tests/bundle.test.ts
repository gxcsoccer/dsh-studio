/**
 * Built-bundle acceptance — the artifact `dsh` actually serves.
 *
 * Every other test in this package imports `src/`. That proves the logic and
 * proves nothing about the file the browser downloads: `lib/client.js` is a
 * *classic script* wrapped in `window.__ModuleLoader__.load({ id, factory })`,
 * with the externals resolved through an injected CommonJS `require`. Two
 * things can therefore be broken while the whole suite is green — the wrapper
 * shape (upstream's `dsh-client-modules` would then fetch a script that does
 * nothing) and the external list (a bundled second copy of React, or a missing
 * one).
 *
 * So this file loads the built bundle the way the shell kernel does, and drives
 * the loaded plugin through the same handshake the native half performs:
 *
 *   window.__ModuleLoader__.load(...) → factory(require) → exports.bootstrap()
 *   → `surface/ready` out, `surface/ping` in, `surface/configure` in.
 *
 * It is skipped, loudly, when `npm run bundle` has not run: a skipped test
 * beats a test that silently asserts nothing, and beats one that shells out to
 * a bundler from inside the runner.
 */

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import { existsSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createContext, runInContext } from 'node:vm'
import { PROTOCOL_VERSION, type ReceiverScope, type WebkitScope } from '../src/client/bridge.ts'
import { REGISTRANT } from '../src/client/manifest.ts'
import { SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW } from '../src/client/slots/index.ts'
import { fakeContext, fakeSlots, type FakeSlots, type SentEnvelope } from './helpers.ts'

/** Built browser bundle, as served at `/plugins/@dsh-studio/studio-client/client.js`. */
const BUNDLE = join(dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'client.js')

/** Package name; the module id upstream keys the plugin by. */
const PACKAGE = '@dsh-studio/studio-client'

/** What one `__ModuleLoader__.load` call carries. */
interface LoadedModule {
  id: string
  factory: (require: (name: string) => unknown) => Record<string, unknown>
}

/** The plugin exports this test drives. */
interface ClientExports {
  inject: string[]
  apply: (...args: never[]) => void
  bootstrap: (ctx: unknown, scope: unknown, config?: unknown) => { bridge: { receive(raw: unknown): void } } | undefined
}

/**
 * Evaluate the built bundle exactly as the shell kernel does.
 * @returns the load call the bundle made, and the module it produced.
 */
function loadBundle(): { loaded: LoadedModule; exports: ClientExports } {
  const calls: LoadedModule[] = []
  const require = createRequire(import.meta.url)
  const context = createContext({
    // The kernel constructs the module table before cordis exists; the bundle
    // only ever touches `load`.
    window: { __ModuleLoader__: { load: (module: LoadedModule) => { calls.push(module) } } },
    console,
  })
  runInContext(readFileSync(BUNDLE, 'utf8'), context, { filename: BUNDLE })
  assert.equal(calls.length, 1, 'the bundle must register exactly one module')
  const loaded = calls[0]
  assert.ok(loaded !== undefined)
  // The injected `require` is the shell's, not Node's: it answers the externals
  // and nothing else. Anything the bundle asks for that is not an external is a
  // packaging bug, so it fails here instead of at runtime in the WebView.
  const exports = loaded.factory(name => {
    assert.ok(name === 'react' || name === 'react/jsx-runtime', `unexpected external ${name}`)
    return require(name)
  }) as unknown as ClientExports
  return { loaded, exports }
}

/** `sidebar.workspaces` as upstream leaves it: declared, occupied at priority 0. */
function officialWorld(): FakeSlots {
  const slots = fakeSlots()
  slots.declare('sidebar', { kind: 'single', scope: 'root' })
  slots.declare(SIDEBAR_WORKSPACES, { kind: 'single', scope: 'root' }, { parent: 'sidebar' })
  slots.occupy(SIDEBAR_WORKSPACES, {
    by: 'ui-workspace',
    children: { [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: { kind: 'single', scope: 'root' } },
  })
  return slots
}

/** A WKWebView-like scope: the outbound handler plus room for the inbound global. */
function studioScope(): WebkitScope & ReceiverScope & { sent: SentEnvelope[] } {
  const sent: SentEnvelope[] = []
  return {
    sent,
    webkit: { messageHandlers: { studio: { postMessage: (body: string) => { sent.push(JSON.parse(body) as SentEnvelope) } } } },
  }
}

const missing = !existsSync(BUNDLE)

describe('the built client bundle', { skip: missing ? `${BUNDLE} is missing — run \`npm run bundle\`` : false }, () => {
  test('it is a __ModuleLoader__ script keyed by the package name', () => {
    const { loaded, exports } = loadBundle()
    assert.equal(loaded.id, PACKAGE)
    // The three members upstream's client Loader reads off a plugin module.
    assert.equal(typeof exports.apply, 'function')
    assert.equal(typeof exports.bootstrap, 'function')
    // Spread first: the array was minted inside the vm realm, so a
    // deep-strict-equal against a host array fails on the prototype alone.
    assert.deepEqual([...exports.inject], ['slots'])
  })

  test('React stays external: the bundle asks for it instead of shipping a copy', () => {
    const source = readFileSync(BUNDLE, 'utf8')
    assert.match(source, /require\("react"\)/)
    // A bundled React would be an order of magnitude bigger and would break
    // hooks in the official tree (two React instances, one dispatcher).
    assert.equal(source.includes('ReactCurrentDispatcher'), false)
  })

  test('outside the Studio WebView it stays inert (ADR-0004)', () => {
    const { exports } = loadBundle()
    const slots = officialWorld()
    // No `webkit.messageHandlers.studio`: a plain browser, so nothing installs.
    assert.equal(exports.bootstrap(fakeContext(slots), {}), undefined)
    // The official occupant is the only entry: Studio registered nothing.
    assert.deepEqual(slots.all.map(entry => entry.registrant), ['ui-workspace'])
  })

  test('inside the WebView it hands the host the handshake, answers ping, and applies the W1 manifest', async () => {
    const { exports } = loadBundle()
    const slots = officialWorld()
    const scope = studioScope()
    const studio = exports.bootstrap(fakeContext(slots), scope)
    assert.ok(studio !== undefined)

    // §1.1 — the handshake, with the measured slot table of this build.
    const ready = scope.sent.find(envelope => envelope.m === 'surface/ready')
    assert.equal(ready?.p?.protocol, PROTOCOL_VERSION)
    assert.deepEqual((ready?.p?.slots as Array<{ name: string }>).map(row => row.name),
      ['sidebar', SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW])

    // §1.6 — the host pings, the bundle answers with the echoed seq.
    studio.bridge.receive(JSON.stringify({
      v: PROTOCOL_VERSION, t: 'req', id: 'beat-1', m: 'surface/ping', p: { seq: 3, sentAt: 1_700_000_000_000 },
    }))
    await Promise.resolve()
    const pong = scope.sent.find(envelope => envelope.id === 'beat-1')
    assert.equal(pong?.ok, true)
    assert.equal(pong?.p?.seq, 3)

    // §1.3 / rule 7 — the two-row W1 manifest the studio profile ships.
    studio.bridge.receive(JSON.stringify({
      v: PROTOCOL_VERSION,
      t: 'req',
      id: 'cfg-1',
      m: 'surface/configure',
      p: {
        manifest: {
          [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: { mode: 'retired' },
          [SIDEBAR_WORKSPACES]: { mode: 'native' },
        },
      },
    }))
    await Promise.resolve()
    await Promise.resolve()
    const receipt = scope.sent.find(envelope => envelope.id === 'cfg-1')
    assert.equal(receipt?.ok, true)
    // Applied in manifest order, which the profile writes bottom-up: the hole
    // first, then the section it lets go native.
    assert.deepEqual(receipt?.p?.applied, [SIDEBAR_WORKSPACES_DIRECTORY_FLOW, SIDEBAR_WORKSPACES])
    assert.deepEqual(receipt?.p?.rejected, [])
    // The official entry is still registered underneath — the fallback is intact.
    assert.deepEqual(slots.cell(SIDEBAR_WORKSPACES).map(entry => entry.registrant), [REGISTRANT, 'ui-workspace'])
  })

  test('the one-row manifest the native half currently sends is refused, bottom-up (known-gaps G-4)', async () => {
    const { exports } = loadBundle()
    const slots = officialWorld()
    const scope = studioScope()
    const studio = exports.bootstrap(fakeContext(slots), scope)
    assert.ok(studio !== undefined)
    // `SurfaceManifest.w1Default` in apps/macos carries the parent row only.
    studio.bridge.receive(JSON.stringify({
      v: PROTOCOL_VERSION,
      t: 'req',
      id: 'cfg-2',
      m: 'surface/configure',
      p: { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native', placement: 'evacuated', priority: -1 } } },
    }))
    await Promise.resolve()
    await Promise.resolve()
    const receipt = scope.sent.find(envelope => envelope.id === 'cfg-2')
    assert.equal(receipt?.ok, true)
    assert.deepEqual(receipt?.p?.applied, [])
    const rejected = receipt?.p?.rejected as Array<{ cell: string; reason: string; detail?: string }>
    assert.deepEqual(rejected.map(rejection => rejection.cell), [SIDEBAR_WORKSPACES])
    assert.match(String(rejected[0]?.detail), /rule 7 is bottom-up/)
    // Nothing was taken over, so the official sidebar renders — the app shows
    // the Web UI instead of a blank column, which is the required posture.
    assert.deepEqual(slots.cell(SIDEBAR_WORKSPACES).map(entry => entry.registrant), ['ui-workspace'])
  })
})
