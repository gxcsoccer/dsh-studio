/**
 * Manifest resolution tests — surface-manifest.md §4, one describe block per
 * rule, plus §5 (hot switch) and §1.5 (`priority_conflict` fails loud).
 */

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import type { SlotSpecLike } from '../src/client/upstream.ts'
import {
  DEFAULT_SHADOW_PRIORITY, MIRRORED_PRIORITY, REGISTRANT, classifyRegisterFailure,
  createManifestController, declaredChildrenOf, parseManifest, planManifest, priorityOf, rowOwnership,
  type CellRegistration, type Manifest, type ManifestRuntime, type PinnedSlotContract,
  type SlotEnvironment, type SlotMode,
} from '../src/client/manifest.ts'
import {
  SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_CONTRACT,
  SIDEBAR_WORKSPACES_DIRECTORY_FLOW, SIDEBAR_WORKSPACES_DIRECTORY_FLOW_CONTRACT,
} from '../src/client/slots/index.ts'
import { fakeSlots, type FakeSlots } from './helpers.ts'

/** Both W1 pins, as `index.ts` hands them to the resolver in production. */
const W1_PINS: Record<string, PinnedSlotContract> = {
  [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT,
  [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: SIDEBAR_WORKSPACES_DIRECTORY_FLOW_CONTRACT,
}

/**
 * The W1 manifest, as rule 7 forces it to be written: the section cannot be
 * taken over while its declared child hole is still official, so every fixture
 * that takes the section over lists the hole as well.
 * @param mode - mode of the section row.
 * @param child - mode of the child hole row.
 * @returns the two-row manifest.
 */
const w1 = (mode: SlotMode = 'native', child: SlotMode = 'retired'): Manifest => ({
  [SIDEBAR_WORKSPACES]: { mode },
  [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: { mode: child },
})

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
    const plan = planManifest(w1(), envOf(fakeSlots(), W1_PINS))
    assert.deepEqual(plan.registrations.map(registration => registration.cell), [
      SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW,
    ])
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
    const plan = planManifest(w1('retired'), envOf(slots))
    assert.equal(plan.registrations[0]?.placement, 'evacuated')
    assert.equal(plan.registrations[0]?.mode, 'retired')
  })

  test('the official entry stays registered underneath (ADR-0004 fallback)', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, W1_PINS))
    createManifestController(runtime).configure(w1())
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
    const plan = planManifest(w1('retired'), envOf(slots, W1_PINS))
    assert.deepEqual(plan.registrations[0]?.children, {})
    assert.deepEqual(plan.registrations[0]?.inheritedChildren, [SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
    assert.match(plan.notes.join('\n'), /inherited child declaration/)
  })

  test('a child nobody declared is declared verbatim from the pin', () => {
    const slots = fakeSlots()
    slots.declare(SIDEBAR_WORKSPACES, SINGLE)
    const plan = planManifest(w1(), envOf(slots, W1_PINS))
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
    const plan = planManifest(w1(), envOf(slots, W1_PINS))
    // Both rows go: the section because its child drifted, the child row itself
    // because the live spec is not the one we pinned.
    assert.deepEqual(plan.registrations, [])
    assert.deepEqual(plan.rejected.map(rejection => rejection.slot), [
      SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW,
    ])
    assert.match(String(plan.rejected[0]?.detail), /drifted from the pinned contract/)
  })
})

describe('rule 7 — takeover is bottom-up (G-2)', () => {
  test('the section cannot go native while its declared hole is still official', () => {
    const slots = officialSidebar()
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'native' } }, envOf(slots, W1_PINS))
    assert.deepEqual(plan.registrations, [])
    assert.equal(plan.rejected[0]?.reason, 'bad_payload')
    assert.match(String(plan.rejected[0]?.detail), /take the child over first/)
    assert.match(String(plan.rejected[0]?.detail), /sidebar\.workspaces\.directoryFlow/)
  })

  test('the pin alone is enough to know a child exists: an empty ledger is no excuse', () => {
    // Nothing is registered yet, so nothing would visibly break — and the rule
    // still refuses, because occupancy is a race and the declaration is not.
    const slots = fakeSlots()
    slots.declare(SIDEBAR_WORKSPACES, SINGLE)
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'native' } }, envOf(slots, W1_PINS))
    assert.deepEqual(plan.registrations, [])
    assert.match(String(plan.rejected[0]?.detail), /unlisted/)
  })

  test('listing the child native/retired unlocks the parent, and both are applied', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, W1_PINS))
    const result = createManifestController(runtime).configure(w1('native', 'retired'))
    assert.deepEqual(result.rejected, [])
    assert.deepEqual(result.applied, [SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
  })

  test('a child left web, or merely mirrored, still blocks the parent', () => {
    const slots = officialSidebar()
    for (const child of ['web', 'mirrored'] as const) {
      const plan = planManifest(w1('native', child), envOf(slots, W1_PINS))
      assert.equal(plan.registrations.some(registration => registration.slot === SIDEBAR_WORKSPACES), false)
      assert.match(String(plan.rejected[0]?.detail), /non-native cell/)
    }
  })

  test('one official cell of a keyed child is enough to block it', () => {
    const slots = fakeSlots()
    slots.declare('panel', SINGLE)
    slots.occupy('panel', { by: 'official', children: { 'panel.tabs': KEYED } })
    slots.occupy('panel.tabs', { key: 'left', by: 'official' })
    slots.occupy('panel.tabs', { key: 'right', by: 'official' })
    const plan = planManifest({
      panel: { mode: 'native' },
      // Rule 5 sends `right` back to the official renderer, so the hole is only
      // half ours and the parent must not hide the other half.
      'panel.tabs': { mode: 'native', keys: { right: { mode: 'web' } } },
    }, envOf(slots))
    assert.deepEqual(plan.registrations.map(registration => registration.cell), ['panel.tabs#key=left'])
    assert.equal(plan.rejected[0]?.cell, 'panel')
  })

  test('the check is transitive: a native child with a web grandchild takes the parent down too', () => {
    const slots = fakeSlots()
    slots.declare('panel', SINGLE)
    slots.occupy('panel', { by: 'official', children: { 'panel.body': SINGLE } })
    slots.occupy('panel.body', { by: 'official', children: { 'panel.body.footer': SINGLE } })
    const plan = planManifest({
      panel: { mode: 'native' },
      'panel.body': { mode: 'native' },
    }, envOf(slots))
    assert.deepEqual(plan.registrations, [])
    assert.deepEqual(plan.rejected.map(rejection => rejection.cell), ['panel', 'panel.body'])
    assert.match(String(plan.rejected[0]?.detail), /panel → panel\.body → panel\.body\.footer/)
  })

  test('a cell Studio already holds on the ledger certifies its parent', () => {
    const slots = officialSidebar()
    // A previous configure (or a Studio plugin registering natively) already
    // owns the hole; the manifest need not say so again.
    slots.occupy(SIDEBAR_WORKSPACES_DIRECTORY_FLOW, { priority: DEFAULT_SHADOW_PRIORITY, by: REGISTRANT })
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'native' } }, envOf(slots, W1_PINS))
    assert.deepEqual(plan.registrations.map(registration => registration.cell), [SIDEBAR_WORKSPACES])
    assert.match(plan.notes.join('\n'), /ledger evidence/)
  })

  test('a mirrored Studio entry is not ownership: it never wins the cell', () => {
    const slots = officialSidebar()
    slots.occupy(SIDEBAR_WORKSPACES_DIRECTORY_FLOW, { priority: MIRRORED_PRIORITY, by: REGISTRANT })
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'native' } }, envOf(slots, W1_PINS))
    assert.deepEqual(plan.registrations, [])
  })

  test('a mirrored parent is exempt: a passenger hides nothing', () => {
    const slots = officialSidebar()
    const plan = planManifest({ [SIDEBAR_WORKSPACES]: { mode: 'mirrored' } }, envOf(slots, W1_PINS))
    assert.equal(plan.registrations.length, 1)
    assert.deepEqual(plan.rejected, [])
  })

  test('rules 6 and 7 read one child set, so they cannot disagree', () => {
    const slots = officialSidebar()
    const env = envOf(slots, W1_PINS)
    assert.deepEqual([...declaredChildrenOf(SIDEBAR_WORKSPACES, env).keys()], [SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
    // The pin knows the name even when the ledger does not.
    assert.deepEqual([...declaredChildrenOf(SIDEBAR_WORKSPACES, envOf(fakeSlots(), W1_PINS)).keys()],
      [SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
  })

  test('ownership of a row is all-or-nothing across its cells', () => {
    assert.equal(rowOwnership(undefined), 'unlisted')
    assert.equal(rowOwnership({ mode: 'native' }), 'owned')
    assert.equal(rowOwnership({ mode: 'retired', keys: { a: {} } }), 'owned')
    assert.equal(rowOwnership({ mode: 'native', ids: { a: { mode: 'web' } } }), 'shared')
    assert.equal(rowOwnership({ keys: { a: { mode: 'native' } } }), 'shared')
    assert.equal(rowOwnership({ mode: 'web' }), 'shared')
  })
})

describe('failing loud (§1.5)', () => {
  test('an occupied priority is a priority_conflict, never a relocation', () => {
    const slots = officialSidebar()
    // Another plugin already sits at -1.
    slots.occupy(SIDEBAR_WORKSPACES, { priority: -1, by: 'some-other-plugin' })
    const plan = planManifest(w1(), envOf(slots))
    assert.equal(plan.rejected[0]?.reason, 'priority_conflict')
    assert.match(String(plan.rejected[0]?.detail), /a human must decide/)
    assert.deepEqual(plan.registrations.map(registration => registration.slot), [SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
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
    const env = envOf(slots, W1_PINS)
    const controller = createManifestController({
      env,
      install: () => { throw new Error('slot "sidebar.workspaces" already has an entry at priority -1') },
    })
    const result = controller.configure(w1())
    assert.deepEqual(result.applied, [])
    assert.equal(result.rejected[0]?.reason, 'priority_conflict')
    assert.deepEqual(controller.active, [])
  })
})

describe('hot switching (§5)', () => {
  const manifest: Manifest = w1('retired')

  test('a patch replaces one row and re-applies without touching the rest', () => {
    const slots = officialSidebar()
    slots.declare('details', SINGLE)
    const runtime = runtimeOf(envOf(slots, W1_PINS))
    const controller = createManifestController(runtime)
    controller.configure({ ...manifest, details: { mode: 'native' } })
    assert.deepEqual([...controller.active].sort(), [
      'details', SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW,
    ])

    // Rolling the section back to web while keeping the hole native is legal —
    // that is the bottom-up ordering of rule 7 run in reverse.
    const result = controller.reconfigure(w1('web'))
    assert.deepEqual([...result.applied].sort(), ['details', SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
    assert.deepEqual([...controller.active].sort(), ['details', SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
    assert.equal(runtime.installed.some(registration => registration.slot === SIDEBAR_WORKSPACES), false)
  })

  test('flipping back to native re-registers the same cell', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, W1_PINS))
    const controller = createManifestController(runtime)
    controller.configure(manifest)
    controller.reconfigure(w1('web', 'web'))
    const back = controller.reconfigure(w1('native'))
    assert.deepEqual(back.applied, [SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
    assert.equal(runtime.installed.length, 2)
  })

  test('a cell dropped from a full manifest falls back to rule 1', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, W1_PINS))
    const controller = createManifestController(runtime)
    controller.configure(manifest)
    controller.configure({})
    assert.deepEqual(controller.active, [])
    assert.deepEqual(runtime.installed, [])
  })

  test('disposeAll releases every cell, which is the pure-Web fallback', () => {
    const slots = officialSidebar()
    const runtime = runtimeOf(envOf(slots, W1_PINS))
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
