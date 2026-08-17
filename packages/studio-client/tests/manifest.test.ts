/**
 * Manifest resolution tests — surface-manifest.md §4, one describe block per
 * rule, plus §5 (hot switch) and §1.5 (`priority_conflict` fails loud).
 */

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import type { SlotSpecLike } from '@deepseek-ai/dsh-client-ui-slots'
import {
  DEFAULT_SHADOW_PRIORITY, MIRRORED_PRIORITY, classifyRegisterFailure, createManifestController,
  parseManifest, planManifest, priorityOf,
  type CellRegistration, type Manifest, type ManifestRuntime, type PinnedSlotContract,
  type SlotEnvironment,
} from '../src/client/manifest.ts'
import { SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_CONTRACT, SIDEBAR_WORKSPACES_DIRECTORY_FLOW } from '../src/client/slots/index.ts'
import { fakeSlots, type FakeSlots } from './helpers.ts'

const SINGLE: SlotSpecLike = { kind: 'single', scope: 'root' }
const KEYED: SlotSpecLike = { kind: 'keyed', scope: 'session' }
const LIST: SlotSpecLike = { kind: 'list', scope: 'root' }

/** Ledger view over the fake registry plus a pin table. */
function envOf(slots: FakeSlots, pins: Record<string, PinnedSlotContract> = {}): SlotEnvironment {
  return {
    spec: slot => slots.spec(slot),
    entries: slot => slots.entries(slot),
    pinned: slot => pins[slot],
  }
}

/** A runtime that records installs instead of rendering anything. */
function runtimeOf(env: SlotEnvironment): ManifestRuntime & { readonly installed: CellRegistration[] } {
  const installed: CellRegistration[] = []
  return {
    env,
    installed,
    install(registration) {
      installed.push(registration)
      return () => {
        const index = installed.indexOf(registration)
        if (index >= 0) installed.splice(index, 1)
      }
    },
  }
}

/** The official world W1 targets: sidebar.workspaces held by ui-workspace at priority 0. */
function officialSidebar(): FakeSlots {
  const slots = fakeSlots()
  slots.declare('sidebar', SINGLE)
  slots.declare(SIDEBAR_WORKSPACES, SINGLE, { parent: 'sidebar' })
  slots.occupy(SIDEBAR_WORKSPACES, {
    by: 'ui-workspace',
    children: { [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: { kind: 'single', scope: 'root' } },
  })
  return slots
}

describe('parsing untrusted input (§5: the peer is a sandbox full of other people’s code)', () => {
  test('a non-object manifest is one bad_payload rejection, not a crash', () => {
    const parsed = parseManifest('nope')
    assert.deepEqual(parsed.manifest, {})
    assert.equal(parsed.rejected[0]?.reason, 'bad_payload')
  })

  test('a bad row is rejected while its siblings survive', () => {
    const parsed = parseManifest({
      'a.good': { mode: 'native' },
      'b.badMode': { mode: 'hidden' },
      'c.badPlacement': { placement: 'floating' },
      'd.badPriority': { priority: 1.5 },
      'e.notAnObject': 7,
    })
    assert.deepEqual(Object.keys(parsed.manifest), ['a.good'])
    assert.deepEqual(parsed.rejected.map(rejection => rejection.cell).sort(), [
      'b.badMode', 'c.badPlacement', 'd.badPriority', 'e.notAnObject',
    ])
    // surface-manifest.md §7: a fifth state must be impossible to express.
    assert.match(String(parsed.rejected.find(r => r.cell === 'b.badMode')?.detail), /web\|mirrored\|native\|retired/)
  })

  test('nested keys/ids rows are validated too', () => {
    const parsed = parseManifest({ 'a': { mode: 'native', keys: { user: { mode: 'web' }, bad: { mode: 'x' } } } })
    assert.equal(parsed.rejected[0]?.reason, 'bad_payload')
    assert.deepEqual(parsed.manifest, {})
  })
})

describe('rule 1 — an unlisted slot is web', () => {
  test('slots absent from the manifest are never touched', () => {
    const slots = officialSidebar()
    slots.declare('sidebar.settings', SINGLE, { parent: 'sidebar' })
    const plan = planManifest({}, envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }))
    assert.deepEqual(plan.registrations, [])
    assert.deepEqual(plan.rejected, [])
  })

  test('a listed slot this build does not have is rejected, not guessed', () => {
    const plan = planManifest({ 'sidebar.renamedUpstream': { mode: 'native' } }, envOf(fakeSlots()))
    assert.equal(plan.rejected[0]?.reason, 'slot_not_declared')
  })

  test('a live spec that drifted from the pin is rejected (ARCHITECTURE.md §7)', () => {
    const slots = fakeSlots()
    // Upstream turned the single hole into a list: our pinned takeover no
    // longer describes reality, and taking the cell anyway would be a guess.
    slots.declare(SIDEBAR_WORKSPACES, LIST)
    const plan = planManifest(
      { [SIDEBAR_WORKSPACES]: { mode: 'native' } },
      envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }),
    )
    assert.equal(plan.rejected[0]?.reason, 'slot_not_declared')
    assert.match(String(plan.rejected[0]?.detail), /drifted from the pinned contract/)
  })

  test('an undeclared but pinned slot plans anyway: registration is deferred', () => {
    const plan = planManifest(
      { [SIDEBAR_WORKSPACES]: { mode: 'native' } },
      envOf(fakeSlots(), { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }),
    )
    assert.equal(plan.registrations.length, 1)
    assert.match(plan.notes.join('\n'), /registration is deferred/)
  })
})

describe('rule 2 — mode web registers nothing at all', () => {
  test('a web row produces a released cell and no registration', () => {
    const slots = officialSidebar()
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'web' } }, envOf(slots))
    assert.deepEqual(plan.registrations, [])
    assert.deepEqual(plan.released, [SIDEBAR_WORKSPACES])
  })

  test('an empty component is never registered: the cell must stay official', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }))
    const controller = createManifestController(runtime)
    controller.configure({ [SIDEBAR_WORKSPACES]: { mode: 'web' } })
    assert.deepEqual(runtime.installed, [])
    assert.deepEqual(controller.active, [])
  })
})

describe('rule 3 — mirrored registers above the official entry', () => {
  test('the priority is +1 regardless of what the row asks for', () => {
    assert.equal(priorityOf('mirrored', undefined), MIRRORED_PRIORITY)
    assert.equal(priorityOf('mirrored', -5), MIRRORED_PRIORITY)
    assert.equal(MIRRORED_PRIORITY, 1)
  })

  test('a mirrored cell never claims the child declarations it cannot render', () => {
    const slots = officialSidebar()
    const plan = planManifest(
      { [SIDEBAR_WORKSPACES]: { mode: 'mirrored' } },
      envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }),
    )
    const registration = plan.registrations[0]
    assert.equal(registration?.priority, MIRRORED_PRIORITY)
    assert.deepEqual(registration?.children, {})
    assert.deepEqual(registration?.inheritedChildren, [])
  })

  test('the plan records that upstream renders only the cell winner', () => {
    const slots = officialSidebar()
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'mirrored' } }, envOf(slots))
    assert.match(plan.notes.join('\n'), /mirrored registration is inert under upstream shadowing/)
  })
})

describe('rule 4 — native and retired take the cell at priority -1', () => {
  test('the default shadow priority is one below the official 0', () => {
    assert.equal(priorityOf('native', undefined), DEFAULT_SHADOW_PRIORITY)
    assert.equal(priorityOf('retired', undefined), DEFAULT_SHADOW_PRIORITY)
    assert.equal(DEFAULT_SHADOW_PRIORITY, -1)
  })

  test('an explicit priority is honoured', () => {
    assert.equal(priorityOf('native', -7), -7)
  })

  test('the placement defaults to evacuated, the form that needs no geometry', () => {
    const slots = officialSidebar()
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'retired' } }, envOf(slots))
    assert.equal(plan.registrations[0]?.placement, 'evacuated')
    assert.equal(plan.registrations[0]?.mode, 'retired')
  })

  test('the official entry stays registered underneath (ADR-0004 fallback)', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }))
    createManifestController(runtime).configure({ [SIDEBAR_WORKSPACES]: { mode: 'native' } })
    assert.equal(slots.entries(SIDEBAR_WORKSPACES).length, 1)
    assert.equal(runtime.installed[0]?.priority, -1)
  })
})

describe('rule 5 — keys and ids override the parent mode', () => {
  test('a keyed row applies the parent mode to observed keys and the override to listed ones', () => {
    const slots = fakeSlots()
    slots.declare('conversation.chat.node', KEYED)
    slots.occupy('conversation.chat.node', { key: 'user', by: 'ui-conversation' })
    slots.occupy('conversation.chat.node', { key: 'assistant-step', by: 'ui-conversation' })
    slots.occupy('conversation.chat.node', { key: 'unknown', by: 'ui-conversation' })
    const plan = planManifest({
      'conversation.chat.node': {
        mode: 'native',
        keys: { 'assistant-step': { mode: 'mirrored' }, unknown: { mode: 'web' } },
      },
    }, envOf(slots))
    assert.deepEqual(
      plan.registrations.map(registration => [registration.key, registration.mode, registration.priority]).sort(),
      [['assistant-step', 'mirrored', 1], ['user', 'native', -1]],
    )
    // The official fallback renderer keeps its cell.
    assert.deepEqual(plan.released, ['conversation.chat.node#key=unknown'])
  })

  test('a list row can replace exactly one entry and leave the others official', () => {
    const slots = fakeSlots()
    slots.declare('sidebar.footer.action', LIST)
    slots.occupy('sidebar.footer.action', { id: 'settings-trigger', by: 'ui-settings' })
    slots.occupy('sidebar.footer.action', { id: 'third-party', by: 'someone-else' })
    const plan = planManifest({
      'sidebar.footer.action': { ids: { 'settings-trigger': { mode: 'native' } } },
    }, envOf(slots))
    assert.deepEqual(plan.registrations.map(registration => registration.id), ['settings-trigger'])
    assert.deepEqual(plan.released, ['sidebar.footer.action#id=third-party'])
  })

  test('a key listed with no mode inherits the parent mode', () => {
    const slots = fakeSlots()
    slots.declare('tool.call.toolview', KEYED)
    const plan = planManifest({
      'tool.call.toolview': { mode: 'native', keys: { read: {}, write: { mode: 'web' } } },
    }, envOf(slots))
    assert.deepEqual(plan.registrations.map(registration => [registration.key, registration.mode]), [['read', 'native']])
    assert.deepEqual(plan.released, ['tool.call.toolview#key=write'])
  })

  test('a nested placement overrides the row placement', () => {
    const slots = fakeSlots()
    slots.declare('conversation.input.model', KEYED)
    const plan = planManifest({
      'conversation.input.model': { mode: 'native', placement: 'evacuated', keys: { picker: { placement: 'overlay' } } },
    }, envOf(slots))
    assert.equal(plan.registrations[0]?.placement, 'overlay')
  })

  test('keys on a single slot, or ids on a keyed slot, are bad_payload', () => {
    const slots = fakeSlots()
    slots.declare('details', SINGLE)
    slots.declare('chat.node', KEYED)
    const plan = planManifest({
      details: { mode: 'native', keys: { a: {} } },
      'chat.node': { mode: 'native', ids: { b: {} } },
    }, envOf(slots))
    assert.deepEqual(plan.rejected.map(rejection => rejection.reason), ['bad_payload', 'bad_payload'])
    assert.deepEqual(plan.registrations, [])
  })
})

describe('rule 6 — declaring is claiming, and there is no partial application', () => {
  test('a child the shadowed occupant declared is inherited, not re-declared', () => {
    const slots = officialSidebar()
    const plan = planManifest(
      { [SIDEBAR_WORKSPACES]: { mode: 'retired' } },
      envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }),
    )
    assert.deepEqual(plan.registrations[0]?.children, {})
    assert.deepEqual(plan.registrations[0]?.inheritedChildren, [SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
    assert.match(plan.notes.join('\n'), /inherited child declaration/)
  })

  test('a child nobody declared is declared verbatim from the pin', () => {
    const slots = fakeSlots()
    slots.declare(SIDEBAR_WORKSPACES, SINGLE)
    const plan = planManifest(
      { [SIDEBAR_WORKSPACES]: { mode: 'native' } },
      envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }),
    )
    assert.deepEqual(plan.registrations[0]?.children, {
      [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: { kind: 'single', scope: 'root' },
    })
  })

  test('one unaccountable child rejects the whole row', () => {
    const slots = fakeSlots()
    slots.declare('panel', SINGLE)
    const incompletePin: PinnedSlotContract = {
      slot: 'panel',
      spec: SINGLE,
      childNames: ['panel.a', 'panel.b'],
      childSpecs: { 'panel.a': SINGLE },
    }
    const env = envOf(slots, { panel: incompletePin })
    const plan = planManifest({ panel: { mode: 'native' } }, env)
    assert.deepEqual(plan.registrations, [])
    assert.equal(plan.rejected[0]?.reason, 'slot_not_declared')
    assert.match(String(plan.rejected[0]?.detail), /panel\.b/)

    // "Not partial" means the runtime installed nothing either — no half-native
    // slot with a blank child hole.
    const runtime = runtimeOf(env)
    const result = createManifestController(runtime).configure({ panel: { mode: 'native' } })
    assert.deepEqual(runtime.installed, [])
    assert.deepEqual(result.applied, [])
    assert.equal(result.rejected.length, 1)
  })

  test('a child whose live declaration drifted from the pin rejects the row', () => {
    const slots = fakeSlots()
    slots.declare(SIDEBAR_WORKSPACES, SINGLE)
    slots.occupy(SIDEBAR_WORKSPACES, { by: 'ui-workspace', children: { [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: KEYED } })
    const plan = planManifest(
      { [SIDEBAR_WORKSPACES]: { mode: 'native' } },
      envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }),
    )
    assert.deepEqual(plan.registrations, [])
    assert.match(String(plan.rejected[0]?.detail), /drifted from the pinned contract/)
  })
})

describe('failing loud (§1.5)', () => {
  test('an occupied priority is a priority_conflict, never a relocation', () => {
    const slots = officialSidebar()
    // Another plugin already sits at -1.
    slots.occupy(SIDEBAR_WORKSPACES, { priority: -1, by: 'some-other-plugin' })
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'native' } }, envOf(slots))
    assert.equal(plan.rejected[0]?.reason, 'priority_conflict')
    assert.match(String(plan.rejected[0]?.detail), /a human must decide/)
    assert.deepEqual(plan.registrations, [])
  })

  test('a chain slot cannot be taken over by the generic proxy', () => {
    const slots = fakeSlots()
    slots.declare('conversation.chain', { kind: 'chain', scope: 'session' })
    const plan = planManifest({ 'conversation.chain': { mode: 'native' } }, envOf(slots))
    assert.equal(plan.rejected[0]?.reason, 'bad_payload')
    assert.match(String(plan.rejected[0]?.detail), /selector/)
  })

  test('upstream register failures map onto the closed error set', () => {
    assert.equal(classifyRegisterFailure(new Error('slot "x" already has an entry at priority -1')), 'priority_conflict')
    assert.equal(classifyRegisterFailure(new Error('slot "x.y" is already declared')), 'slot_not_declared')
    assert.equal(classifyRegisterFailure(new Error('slot "x" is not declared')), 'slot_not_declared')
    assert.equal(classifyRegisterFailure(new TypeError('undefined is not a function')), 'internal')
  })

  test('an install that throws is reported and leaves no ghost cell', () => {
    const slots = officialSidebar()
    const env = envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT })
    const controller = createManifestController({
      env,
      install: () => { throw new Error('slot "sidebar.workspaces" already has an entry at priority -1') },
    })
    const result = controller.configure({ [SIDEBAR_WORKSPACES]: { mode: 'native' } })
    assert.deepEqual(result.applied, [])
    assert.equal(result.rejected[0]?.reason, 'priority_conflict')
    assert.deepEqual(controller.active, [])
  })
})

describe('hot switching (§5)', () => {
  const manifest: Manifest = { [SIDEBAR_WORKSPACES]: { mode: 'retired' } }

  test('a patch replaces one row and re-applies without touching the rest', () => {
    const slots = officialSidebar()
    slots.declare('details', SINGLE)
    const runtime = runtimeOf(envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }))
    const controller = createManifestController(runtime)
    controller.configure({ ...manifest, details: { mode: 'native' } })
    assert.deepEqual([...controller.active].sort(), ['details', SIDEBAR_WORKSPACES])

    const result = controller.reconfigure({ [SIDEBAR_WORKSPACES]: { mode: 'web' } })
    assert.deepEqual(result.applied, ['details'])
    assert.deepEqual(controller.active, ['details'])
    assert.deepEqual(runtime.installed.map(registration => registration.cell), ['details'])
  })

  test('flipping back to native re-registers the same cell', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }))
    const controller = createManifestController(runtime)
    controller.configure(manifest)
    controller.reconfigure({ [SIDEBAR_WORKSPACES]: { mode: 'web' } })
    const back = controller.reconfigure({ [SIDEBAR_WORKSPACES]: { mode: 'native' } })
    assert.deepEqual(back.applied, [SIDEBAR_WORKSPACES])
    assert.equal(runtime.installed.length, 1)
  })

  test('a cell dropped from a full manifest falls back to rule 1', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }))
    const controller = createManifestController(runtime)
    controller.configure(manifest)
    controller.configure({})
    assert.deepEqual(controller.active, [])
    assert.deepEqual(runtime.installed, [])
  })

  test('disposeAll releases every cell, which is the pure-Web fallback', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, { [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT }))
    const controller = createManifestController(runtime)
    controller.configure(manifest)
    controller.disposeAll()
    assert.deepEqual(controller.active, [])
    assert.deepEqual(runtime.installed, [])
  })

  test('the retained manifest is what a patch merges onto', () => {
    const slots = officialSidebar()
    const controller = createManifestController(runtimeOf(envOf(slots)))
    controller.configure({ [SIDEBAR_WORKSPACES]: { mode: 'web', placement: 'overlay' } })
    controller.reconfigure({ 'other.slot': { mode: 'web' } })
    assert.deepEqual(Object.keys(controller.current).sort(), ['other.slot', SIDEBAR_WORKSPACES])
  })
})
