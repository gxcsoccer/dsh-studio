/**
 * The host wire golden — known-gaps.md G-7.
 *
 * Both halves read the SAME bytes: Swift asserts its `surface/configure`
 * payload equals `contracts/w1-surface-configure.json`, and this file feeds
 * that very file through `parseManifest` + `planManifest`. Testing one's own
 * hand-written fixture is exactly what let the empty `keys: {}` through: the
 * host produced it, the client rejects it, and neither side's fixture had it.
 */

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { describe, test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { parseManifest, planManifest, type PinnedSlotContract, type SlotEnvironment } from '../src/client/manifest.ts'
import {
  SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_CONTRACT,
  SIDEBAR_WORKSPACES_DIRECTORY_FLOW, SIDEBAR_WORKSPACES_DIRECTORY_FLOW_CONTRACT,
} from '../src/client/slots/index.ts'
import { fakeSlots, type FakeSlots } from './helpers.ts'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..')
const GOLDEN = join(REPO_ROOT, 'contracts', 'w1-surface-configure.json')

const W1_PINS: Record<string, PinnedSlotContract> = {
  [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT,
  [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: SIDEBAR_WORKSPACES_DIRECTORY_FLOW_CONTRACT,
}

/** The official world W1 targets, as `manifest.test.ts` models it. */
function officialSidebar(): FakeSlots {
  const slots = fakeSlots()
  slots.declare('sidebar', { kind: 'single', scope: 'root' })
  slots.declare(SIDEBAR_WORKSPACES, { kind: 'single', scope: 'root' }, { parent: 'sidebar' })
  slots.occupy(SIDEBAR_WORKSPACES, {
    by: 'ui-workspace',
    children: { [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: { kind: 'single', scope: 'root' } },
  })
  return slots
}

function envOf(slots: FakeSlots): SlotEnvironment {
  return {
    spec: slot => slots.spec(slot),
    entries: slot => slots.entries(slot),
    pinned: slot => W1_PINS[slot],
  }
}

describe('the host wire golden (contracts/w1-surface-configure.json, G-7)', () => {
  const raw = JSON.parse(readFileSync(GOLDEN, 'utf8')) as { manifest: unknown }

  test('the exact bytes the host sends parse with zero rejections', () => {
    const parsed = parseManifest(raw.manifest)
    assert.deepEqual(parsed.rejected, [])
    assert.deepEqual(Object.keys(parsed.manifest).sort(), [
      SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW,
    ])
  })

  test('no row carries keys/ids: on a single slot their mere presence is bad_payload', () => {
    for (const [slot, row] of Object.entries(raw.manifest as Record<string, Record<string, unknown>>)) {
      assert.equal('keys' in row, false, `${slot} carries keys`)
      assert.equal('ids' in row, false, `${slot} carries ids`)
    }
  })

  test('planning the golden assembles both cells and rejects nothing', () => {
    const { manifest } = parseManifest(raw.manifest)
    const plan = planManifest(manifest, envOf(officialSidebar()))
    assert.deepEqual(plan.rejected, [])
    assert.deepEqual(plan.registrations.map(registration => registration.cell), [
      SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW,
    ])
  })
})
