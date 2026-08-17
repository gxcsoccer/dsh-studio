/**
 * Host `Config` tests — surface-manifest.md §1/§2 (the manifest is a plugin
 * config), §6 (a patch is a user's rollback lever) and §7 (what must stay
 * inexpressible).
 *
 * The last describe block is the important one: it feeds the host's own wire
 * projection into the client's parser, so the two halves of the contract are
 * proven to agree instead of being maintained in parallel by hand.
 */

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import { parseManifest, planManifest, type PinnedSlotContract, type SlotEnvironment } from '@dsh-studio/studio-client/src/client/manifest.ts'
import type { SlotSpecLike, StoredEntry } from '@dsh-studio/studio-client/src/client/upstream.ts'
import { assertLoopback } from '../src/bridge-server.ts'
import {
  Config, DEFAULT_BRIDGE_PORT, DEFAULT_RETENTION, LOOPBACK_ADDRESS,
  surfaceCensus, toWireManifest,
} from '../src/config.ts'
import { HANDSHAKE_SEGMENTS, resolveHandshakePath } from '../src/handshake-path.ts'
import type { HostContext } from '../src/host-context.ts'

const SLOT = 'sidebar.workspaces'

/**
 * Resolve a config through the schema, as cordis does before `apply`.
 *
 * The cast mirrors reality: what a user writes in `cordis.patch.yml` is a
 * partial, untyped fragment, and validating it into the total shape is exactly
 * the schema's job.
 * @param raw - user-authored configuration.
 * @returns the resolved config.
 */
const resolve = (raw: unknown): Config => new Config(raw as Config)

describe('defaults', () => {
  test('an empty config is a running data channel and an untouched Web UI', () => {
    const config = resolve({})
    assert.deepEqual(config.bridge, {
      port: DEFAULT_BRIDGE_PORT, retention: DEFAULT_RETENTION, tokenFile: '', shellUrl: '',
    })
    assert.deepEqual(config.surface, {})
    assert.equal(config.compareHotkey, 'opt+shift+d')
    assert.equal(DEFAULT_BRIDGE_PORT, 43180)
    assert.equal(LOOPBACK_ADDRESS, '127.0.0.1')
  })

  test('the shell URL is an override, not a default: unset means "ask the carrier" (§2.1)', () => {
    // The handshake carries what the deployment knows and nothing more. An
    // invented default (127.0.0.1:3080) made the native half load the wrong
    // page on any run that moved the web bind — so the schema keeps the field
    // empty and `resolveShellUrl` derives the truth from `webServer`.
    assert.equal(resolve({}).bridge.shellUrl, '')
    assert.equal(resolve({ bridge: { shellUrl: 'http://proxy.internal' } }).bridge.shellUrl, 'http://proxy.internal')
  })

  test('a listed row defaults to web / evacuated / -1', () => {
    const config = resolve({ surface: { [SLOT]: {} } })
    assert.deepEqual(config.surface[SLOT], {
      mode: 'web', placement: 'evacuated', priority: -1, keys: {}, ids: {},
    })
  })

  test('the bind address is not a config member, and writing one changes nothing (§5)', () => {
    const config = resolve({ bridge: { host: '0.0.0.0' } })
    // Schemastery passes unknown members through rather than rejecting them
    // (upstream behaviour, shared with cordis config patching), so the guard
    // that matters is not the schema: the bind address has exactly one
    // authority, and it is `assertLoopback` in code.
    assert.equal(config.bridge.port, DEFAULT_BRIDGE_PORT)
    assert.throws(() => assertLoopback('0.0.0.0'), /binds 127\.0\.0\.1 only/)
    assert.equal(assertLoopback(LOOPBACK_ADDRESS), undefined)
  })
})

describe('validation (§7 — some things must stay inexpressible)', () => {
  test('a fifth mode is rejected', () => {
    assert.throws(() => resolve({ surface: { [SLOT]: { mode: 'hidden' } } }))
  })

  test('a placement outside the two landing forms is rejected', () => {
    assert.throws(() => resolve({ surface: { [SLOT]: { placement: 'floating' } } }))
  })

  test('a fractional priority is rejected', () => {
    assert.throws(() => resolve({ surface: { [SLOT]: { priority: 0.5 } } }))
  })

  test('a negative port is rejected', () => {
    assert.throws(() => resolve({ bridge: { port: -1 } }))
  })

  test('there is nowhere to put a CSS selector or a pixel geometry', () => {
    const config = resolve({ surface: { [SLOT]: { mode: 'native' } } })
    assert.deepEqual(Object.keys(config.surface[SLOT] ?? {}).sort(), ['ids', 'keys', 'mode', 'placement', 'priority'])
  })
})

describe('nested key/id overrides (rule 5)', () => {
  test('a listed key with no mode stays empty, so rule 5 can inherit', () => {
    // If the nested schema defaulted `mode`, this would materialize as
    // `mode: web` and "the parent mode applies to unlisted keys" would be
    // unreachable for a listed-but-empty key.
    const config = resolve({ surface: { 'chat.node': { mode: 'native', keys: { user: {} } } } })
    assert.deepEqual(config.surface['chat.node']?.keys, { user: {} })
  })

  test('an override may name only mode / placement / priority', () => {
    const config = resolve({
      surface: { 'chat.node': { mode: 'native', keys: { user: { mode: 'web', placement: 'overlay', priority: -2 } } } },
    })
    assert.deepEqual(config.surface['chat.node']?.keys.user, { mode: 'web', placement: 'overlay', priority: -2 })
  })

  test('a malformed override is rejected', () => {
    assert.throws(() => resolve({ surface: { 'chat.node': { keys: { user: { mode: 'nope' } } } } }))
  })
})

describe('the wire projection', () => {
  test('empty keys/ids tables are dropped: they are a schema artifact', () => {
    const manifest = toWireManifest(resolve({ surface: { [SLOT]: { mode: 'native' } } }))
    assert.deepEqual(manifest, { [SLOT]: { mode: 'native', placement: 'evacuated', priority: -1 } })
  })

  test('a non-empty table rides along verbatim', () => {
    const manifest = toWireManifest(resolve({
      surface: { 'chat.node': { mode: 'native', keys: { user: { mode: 'web' } } } },
    }))
    assert.deepEqual(manifest['chat.node']?.keys, { user: { mode: 'web' } })
    assert.equal('ids' in (manifest['chat.node'] ?? {}), false)
  })

  test('the census is derived from the config, not hand-maintained', () => {
    const config = resolve({
      surface: {
        a: { mode: 'native' }, b: { mode: 'retired' }, c: { mode: 'mirrored' },
        d: { mode: 'web' }, e: { mode: 'native' },
      },
    })
    assert.deepEqual(surfaceCensus(config), { web: 1, mirrored: 1, native: 2, retired: 1 })
  })
})

describe('the handshake path', () => {
  test('an explicit tokenFile wins', () => {
    const ctx = { dshHomePath: () => '/never/used' } as unknown as HostContext
    assert.equal(resolveHandshakePath(ctx, '/tmp/studio/bridge.json'), '/tmp/studio/bridge.json')
  })

  test('otherwise the host resolver names it — $DSH_HOME is never re-derived', () => {
    const seen: string[][] = []
    const ctx = {
      dshHomePath: (...segments: string[]) => { seen.push(segments); return `/home/.dsh/${segments.join('/')}` },
    } as unknown as HostContext
    assert.equal(resolveHandshakePath(ctx, ''), '/home/.dsh/studio/bridge.json')
    assert.deepEqual(seen, [[...HANDSHAKE_SEGMENTS]])
  })

  test('a host without the resolver must be told the path explicitly', () => {
    assert.throws(() => resolveHandshakePath({} as unknown as HostContext, ''), /explicit bridge\.tokenFile/)
  })
})

describe('host config and client parser agree (the contract seam)', () => {
  /** A ledger where `sidebar.workspaces` is declared and officially occupied. */
  const env = (pins: Record<string, PinnedSlotContract> = {}): SlotEnvironment => {
    const spec: SlotSpecLike = { kind: 'single', scope: 'root' }
    // `component` is required upstream: an entry is a component plus its
    // options, and the planner reads the options only.
    const official: StoredEntry = { component: () => null, options: { priority: 0 }, registrant: 'ui-workspace' }
    return {
      spec: slot => (slot === SLOT ? spec : undefined),
      entries: slot => (slot === SLOT ? [official] : []),
      pinned: slot => pins[slot],
    }
  }

  test('every mode the config accepts parses on the client with zero rejections', () => {
    const config = resolve({
      surface: {
        [SLOT]: { mode: 'native', placement: 'overlay', priority: -3 },
        'chat.node': { mode: 'mirrored', keys: { user: { mode: 'web' } } },
        'footer.action': { mode: 'retired', ids: { settings: { mode: 'native' } } },
        'left.alone': { mode: 'web' },
      },
    })
    const parsed = parseManifest(toWireManifest(config))
    assert.deepEqual(parsed.rejected, [])
    assert.deepEqual(Object.keys(parsed.manifest).sort(), ['chat.node', 'footer.action', 'left.alone', SLOT])
  })

  test('a native row from the config plans into a registration at its priority', () => {
    const config = resolve({ surface: { [SLOT]: { mode: 'native', placement: 'overlay', priority: -3 } } })
    const plan = planManifest(parseManifest(toWireManifest(config)).manifest, env())
    assert.deepEqual(plan.rejected, [])
    assert.equal(plan.registrations.length, 1)
    assert.equal(plan.registrations[0]?.priority, -3)
    assert.equal(plan.registrations[0]?.placement, 'overlay')
  })

  test('the default row is inert end to end: config default → web → no registration', () => {
    const plan = planManifest(parseManifest(toWireManifest(resolve({ surface: { [SLOT]: {} } }))).manifest, env())
    assert.deepEqual(plan.registrations, [])
    assert.deepEqual(plan.released, [SLOT])
  })

  test('a rollback patch is one line, and it frees the cell', () => {
    // §6: the user edits `cordis.patch.yml`; the resolved config is what the
    // client is then reconfigured with.
    const before = toWireManifest(resolve({ surface: { [SLOT]: { mode: 'native' } } }))
    const after = toWireManifest(resolve({ surface: { [SLOT]: { mode: 'web' } } }))
    assert.equal(planManifest(parseManifest(before).manifest, env()).registrations.length, 1)
    assert.deepEqual(planManifest(parseManifest(after).manifest, env()).registrations, [])
  })
})
