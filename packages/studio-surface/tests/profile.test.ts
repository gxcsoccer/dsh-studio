/**
 * The shipped profile is the authority — so it is what gets tested.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * `known-gaps.md` G-4 says the host adopts the manifest the *runtime* serves
 * (`GET /studio/surface`), not its compiled-in `SurfaceManifest.w1Default`. The
 * runtime's copy comes from `profiles/studio/cordis.patch.yml` and from nowhere
 * else. Every existing test around that row — Swift's `RemoteSurfaceInfoTests`,
 * the wire golden, `config.test.ts` — feeds itself a *hand-written* row that
 * merely claims to be "the two rows from the profile".
 *
 * That is G-7 all over again, and it cost a whole dogfood round: the profile
 * said `placement: evacuated` for `sidebar.workspaces` while every fixture on
 * both sides said `overlay`. Swift was green, TypeScript was green, and the live
 * app mounted the cell with no geometry channel at all — a native rail placed
 * by nobody, exactly the screenshot W1 started from.
 *
 * So: read the real file, compare it to the real shared bytes
 * (`contracts/w1-surface-configure.json`, which Swift's
 * `WireGoldenTests` produces from `w1Default` and the client's
 * `manifest-golden.test.ts` consumes). No fixture in between.
 */

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { describe, test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { parseManifest, planManifest, type PinnedSlotContract, type SlotEnvironment } from '@dsh-studio/studio-client/src/client/manifest.ts'
import type { SlotSpecLike, StoredEntry } from '@dsh-studio/studio-client/src/client/upstream.ts'

/** Repository root (this file lives in `<root>/packages/studio-surface/tests`). */
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..')

const PROFILE = join(ROOT, 'profiles', 'studio', 'cordis.patch.yml')
const GOLDEN = join(ROOT, 'contracts', 'w1-surface-configure.json')

/** One row of the profile's `surface:` block, as authored. */
type ProfileRow = Record<string, string | number>

/**
 * Read the `surface:` block out of the profile.
 *
 * A three-level, scalar-only block does not justify a YAML dependency (the repo
 * has none, on purpose: the runtime owns YAML parsing), and a hand-rolled
 * reader for *this* shape is ~20 lines and fails loudly on anything it does not
 * understand. What it must not do is silently return `{}` when the block moves
 * — hence the two assertions in the caller.
 * @param source - the profile file's text.
 * @returns `slot → row`, values coerced the way YAML would coerce them.
 */
export function readSurfaceBlock(source: string): Record<string, ProfileRow> {
  const lines = source.split('\n')
  const start = lines.findIndex(line => /^\s*surface:\s*$/.test(line))
  assert.notEqual(start, -1, `no \`surface:\` block in ${PROFILE}`)
  const blockIndent = lines[start]?.search(/\S/) ?? 0

  const rows: Record<string, ProfileRow> = {}
  let current: string | undefined
  for (const line of lines.slice(start + 1)) {
    if (line.trim() === '' || line.trim().startsWith('#')) continue
    const indent = line.search(/\S/)
    if (indent <= blockIndent) break                       // block ended
    const slot = /^\s*([\w.]+):\s*$/.exec(line)
    if (slot?.[1] !== undefined) {
      current = slot[1]
      rows[current] = {}
      continue
    }
    const field = /^\s*(\w+):\s*(\S+)\s*$/.exec(line)
    assert.notEqual(field, null, `cannot read profile line: ${line}`)
    assert.notEqual(current, undefined, `field outside a slot row: ${line}`)
    const [, key, raw] = field as unknown as [string, string, string]
    const row = rows[current as string] as ProfileRow
    row[key] = /^-?\d+$/.test(raw) ? Number(raw) : raw
  }
  return rows
}

/** A slot ledger where both W1 cells are declared and officially occupied. */
function env(): SlotEnvironment {
  const spec: SlotSpecLike = { kind: 'single', scope: 'root' }
  // `component` is required upstream: an entry is a component plus its options,
  // and the planner reads the options only.
  const official: StoredEntry = { component: () => null, options: { priority: 0 }, registrant: 'ui-workspace' }
  const pins: Record<string, PinnedSlotContract> = {
    'sidebar.workspaces': {
      slot: 'sidebar.workspaces',
      spec,
      childNames: ['sidebar.workspaces.directoryFlow'],
      childSpecs: { 'sidebar.workspaces.directoryFlow': spec },
    },
    'sidebar.workspaces.directoryFlow': {
      slot: 'sidebar.workspaces.directoryFlow',
      spec,
      childNames: [],
      childSpecs: {},
    },
  }
  return {
    spec: slot => (slot in pins ? spec : undefined),
    entries: slot => (slot in pins ? [official] : []),
    pinned: slot => pins[slot],
  }
}

describe('profiles/studio/cordis.patch.yml is the authority (G-4)', () => {
  const rows = readSurfaceBlock(readFileSync(PROFILE, 'utf8'))
  const golden = JSON.parse(readFileSync(GOLDEN, 'utf8')) as { manifest: Record<string, ProfileRow> }

  test('the profile does not restate the web bundle\'s port as a fact (G-10)', () => {
    // `shellUrl: http://127.0.0.1:3080` shipped here for weeks while
    // scripts/dogfood.sh started the runtime on 3081, so `bridge.json` told the
    // native half to load a port nobody served. The truthful value comes from
    // the `webServer` service now; a hardcoded one here would silently win over
    // it again (it is the documented override).
    const source = readFileSync(PROFILE, 'utf8')
    assert.doesNotMatch(
      source,
      /^\s*shellUrl:\s*\S/m,
      'set shellUrl only for a proxy/tunnel — never to restate the carrier\'s own port',
    )
  })

  test('the reader actually found the two W1 rows', () => {
    assert.deepEqual(Object.keys(rows).sort(), [
      'sidebar.workspaces', 'sidebar.workspaces.directoryFlow',
    ])
  })

  test('every row equals the shared contract bytes, field for field', () => {
    assert.deepEqual(rows, golden.manifest)
  })

  test('`sidebar.workspaces` is overlay: the Web side reserves the cell', () => {
    // The one value the screenshot was about. `evacuated` here means no
    // `slot/rect` ever reaches the host, and the native view is placed by
    // nobody (ARCHITECTURE.md §4.2).
    assert.equal(rows['sidebar.workspaces']?.placement, 'overlay')
    assert.equal(rows['sidebar.workspaces']?.mode, 'native')
  })

  test('the profile plans into two live registrations, bottom-up (rule 7)', () => {
    // Not just "the letters match": the authority is fed through the client's
    // own parser and planner, so a profile that is well-formed but unplannable
    // (rule 6/7 violation) fails here rather than at dogfood time.
    const { manifest, rejected } = parseManifest(rows)
    assert.deepEqual(rejected, [])
    const plan = planManifest(manifest, env())
    assert.deepEqual(plan.rejected, [])
    assert.deepEqual(
      plan.registrations.map(registration => [registration.cell, registration.mode, registration.placement]),
      [
        ['sidebar.workspaces.directoryFlow', 'retired', 'evacuated'],
        ['sidebar.workspaces', 'native', 'overlay'],
      ],
    )
  })
})
