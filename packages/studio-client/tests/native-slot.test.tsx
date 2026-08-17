/**
 * `NativeSlotProxy` tests — reference/native-slot-proxy.md §1 ("四件事"),
 * §2 (`slot/invoke`), ADR-0002 (whitelist) and ADR-0003 (overlay + scroll).
 *
 * `./dom.ts` must be imported before anything that pulls in react-dom.
 */

import assert from 'node:assert/strict'
import { afterEach, describe, test } from 'node:test'
import { createElement } from 'react'
import { fakeResizeObservers, mountHarness, pinGeometry, type Harness } from './dom.ts'
import { createBridge, type Bridge } from '../src/client/bridge.ts'
import { createInstanceLedger, pickActions, type InstanceLedger } from '../src/client/invoke.ts'
import {
  ORCHESTRATION_KEYS, hasScrollableAncestor, nativeSlot, serializeOrchestration, shallowDiff,
  type NativeSlotOptions, type ProxyProps,
} from '../src/client/native-slot.tsx'
import { recordingTransport, type RecordingTransport, type SentEnvelope } from './helpers.ts'

const SLOT = 'sidebar.workspaces'

/** One assembled proxy under test. */
interface Rig {
  bridge: Bridge
  transport: RecordingTransport
  ledger: InstanceLedger
  harness: Harness
  /** Render the proxy with the given props. */
  render(props: ProxyProps): void
  /** Payloads of one event method, in order. */
  events(method: string): Array<Record<string, unknown>>
  /** The instanceId reported by `slot/mount`. */
  instanceId(): string
}

const rigs: Rig[] = []

/**
 * Assemble bridge + ledger + a mounted React root around one registration.
 * @param options - registration facts (defaults to a native, evacuated cell).
 * @param harnessOptions - DOM container options.
 * @returns the rig.
 */
function rig(
  options: Partial<NativeSlotOptions> = {},
  harnessOptions: { scrollable?: boolean } = {},
): Rig {
  const transport = recordingTransport()
  const bridge = createBridge({ transport })
  const ledger = createInstanceLedger()
  const harness = mountHarness(harnessOptions)
  const resolved: NativeSlotOptions = {
    slot: SLOT,
    placement: 'evacuated',
    scope: 'root',
    invocable: true,
    ...options,
  }
  const Component = nativeSlot(bridge, ledger, resolved)
  const instance: Rig = {
    bridge,
    transport,
    ledger,
    harness,
    render(props) { harness.render(createElement(Component, props)) },
    events(method) {
      return transport.ofMethod(method).map(envelope => envelope.p ?? {})
    },
    instanceId() {
      const mount = transport.ofMethod('slot/mount')[0]?.p
      assert.ok(mount !== undefined, 'nothing mounted')
      return mount.instanceId as string
    },
  }
  rigs.push(instance)
  return instance
}

afterEach(() => {
  for (const instance of rigs.splice(0)) instance.harness.unmount()
})

describe('the whitelist (ADR-0002)', () => {
  test('only orchestration members are serialized', () => {
    const props = {
      wide: true,
      collapsed: false,
      width: 240,
      // Domain data: the reason the data channel exists.
      workspaces: [{ id: 'w1', name: 'repo' }],
      session: { id: 's1' },
      // Not orchestration either, just noise.
      className: 'sidebar',
      expandSidebar: () => {},
      absent: undefined,
    }
    assert.deepEqual(serializeOrchestration(props), { wide: true, collapsed: false, width: 240 })
  })

  test('a whitelisted member is projected onto the JSON domain', () => {
    assert.deepEqual(
      serializeOrchestration({ variant: { nested: 1, fn: () => {}, deep: [1, Number.NaN] } }),
      { variant: { nested: 1, deep: [1, null] } },
    )
  })

  test('the list is a whitelist, so an unknown key cannot leak by default', () => {
    assert.equal(ORCHESTRATION_KEYS.has('wide'), true)
    assert.equal(ORCHESTRATION_KEYS.has('messages'), false)
    assert.deepEqual(serializeOrchestration({ someNewUpstreamProp: 'x' }), {})
  })

  test('mount props are the whitelisted share only', () => {
    const instance = rig()
    instance.render({ wide: true, workspaces: [1, 2, 3], expandSidebar: () => {} })
    assert.deepEqual(instance.events('slot/mount')[0]?.props, { wide: true })
  })
})

describe('the shallow diff', () => {
  test('only changed members are reported', () => {
    assert.deepEqual(shallowDiff({ a: 1, b: 2 }, { a: 1, b: 3 }), { b: 3 })
  })

  test('a vanished member is reported as null so the host can unset it', () => {
    assert.deepEqual(shallowDiff({ a: 1 }, {}), { a: null })
  })

  test('an unchanged snapshot produces no patch', () => {
    assert.deepEqual(shallowDiff({ a: 1 }, { a: 1 }), {})
  })
})

describe('the four things it does, and nothing else (§1)', () => {
  test('mount emits exactly one slot/mount with a ULID instance id', () => {
    const instance = rig({ scope: 'session', key: 'main' })
    instance.render({ wide: false, expandSidebar: () => {} })
    const mounts = instance.events('slot/mount')
    assert.equal(mounts.length, 1)
    assert.deepEqual(mounts[0], {
      slot: SLOT,
      instanceId: instance.instanceId(),
      key: 'main',
      scope: 'session',
      props: { wide: false },
      actions: ['expandSidebar'],
    })
    assert.match(instance.instanceId(), /^[0-9A-HJKMNP-TV-Z]{26}$/)
  })

  test('the first render emits no slot/props: the mount already carried them', () => {
    const instance = rig()
    instance.render({ wide: true })
    assert.deepEqual(instance.events('slot/props'), [])
  })

  test('a changed orchestration prop emits one patch, not a full snapshot', () => {
    const instance = rig()
    instance.render({ wide: true, collapsed: false })
    instance.render({ wide: false, collapsed: false })
    assert.deepEqual(instance.events('slot/props'), [
      { instanceId: instance.instanceId(), props: { wide: false } },
    ])
  })

  test('a changed domain prop emits nothing at all', () => {
    const instance = rig()
    instance.render({ wide: true, workspaces: ['a'] })
    instance.transport.clear()
    instance.render({ wide: true, workspaces: ['a', 'b'] })
    assert.deepEqual(instance.transport.sent, [])
  })

  test('a prop that disappeared is patched to null', () => {
    const instance = rig()
    instance.render({ wide: true, label: 'Workspaces' })
    instance.render({ wide: true })
    assert.deepEqual(instance.events('slot/props').at(-1)?.props, { label: null })
  })

  test('unmount emits slot/unmount and leaves no live instance behind', () => {
    const instance = rig()
    instance.render({ wide: true })
    const id = instance.instanceId()
    assert.equal(instance.ledger.size, 1)
    instance.harness.render(null)
    assert.deepEqual(instance.events('slot/unmount'), [{ instanceId: id }])
    assert.equal(instance.ledger.size, 0)
    assert.equal(instance.ledger.slotOf(id), undefined)
  })

  test('a remount is a new native view, hence a new instanceId (§1.4)', () => {
    const instance = rig()
    instance.render({ wide: true })
    const first = instance.instanceId()
    instance.harness.render(null)
    instance.render({ wide: true })
    const ids = instance.events('slot/mount').map(payload => payload.instanceId)
    assert.equal(ids.length, 2)
    assert.notEqual(ids[0], ids[1])
    assert.equal(ids[0], first)
  })

  test('it renders no official DOM, reads none, and injects no CSS', () => {
    const instance = rig()
    instance.render({ wide: true })
    const element = instance.harness.proxyElement(SLOT)
    assert.ok(element !== null)
    assert.equal(element.childNodes.length, 0)
    assert.equal(instance.harness.container.querySelectorAll('style').length, 0)
  })

  test('the ordering of the wire is mount → props → unmount', () => {
    const instance = rig()
    instance.render({ wide: true })
    instance.render({ wide: false })
    instance.harness.render(null)
    assert.deepEqual(
      instance.transport.sent.map((envelope: SentEnvelope) => envelope.m),
      ['slot/mount', 'slot/props', 'slot/unmount'],
    )
  })
})

describe('placement (ARCHITECTURE.md §4)', () => {
  test('evacuated takes no screen area and reports no geometry', () => {
    const instance = rig({ placement: 'evacuated' })
    instance.render({ wide: true })
    assert.equal(instance.harness.proxyElement(SLOT)?.style.display, 'none')
    assert.deepEqual(instance.events('slot/rect'), [])
  })

  test('overlay keeps the layout with an invisible placeholder and reports its rect', () => {
    const restoreGeometry = pinGeometry({ x: 12, y: 34, width: 260, height: 700 })
    try {
      const instance = rig({ placement: 'overlay' })
      instance.render({ wide: true })
      const element = instance.harness.proxyElement(SLOT)
      assert.equal(element?.style.visibility, 'hidden')
      assert.notEqual(element?.style.display, 'none')
      assert.deepEqual(instance.events('slot/rect'), [{
        instanceId: instance.instanceId(),
        rect: { x: 12, y: 34, w: 260, h: 700 },
        scrollable: false,
      }])
    } finally {
      restoreGeometry()
    }
  })

  test('a resize re-measures through ResizeObserver, not a polling loop', () => {
    const observers = fakeResizeObservers()
    const restoreGeometry = pinGeometry({ x: 0, y: 0, width: 100, height: 100 })
    try {
      const instance = rig({ placement: 'overlay' })
      instance.render({ wide: true })
      assert.equal(observers.observed, 1)
      observers.trigger()
      assert.equal(instance.events('slot/rect').length, 2)
      instance.harness.render(null)
      assert.equal(observers.disconnected, 1)
    } finally {
      restoreGeometry()
      observers.restore()
    }
  })

  test('a scroll container ancestor is reported honestly (ADR-0003)', () => {
    const restoreGeometry = pinGeometry({ x: 0, y: 0, width: 10, height: 10 })
    try {
      const instance = rig({ placement: 'overlay' }, { scrollable: true })
      instance.render({ wide: true })
      assert.equal(instance.events('slot/rect')[0]?.scrollable, true)
    } finally {
      restoreGeometry()
    }
  })

  test('hasScrollableAncestor walks up, and a plain ancestor chain is not scrollable', () => {
    const outer = mountHarness({ scrollable: true })
    const plain = mountHarness()
    try {
      const nest = (parent: HTMLElement): HTMLElement => {
        const middle = parent.ownerDocument.createElement('div')
        const leaf = parent.ownerDocument.createElement('div')
        middle.appendChild(leaf)
        parent.appendChild(middle)
        return leaf
      }
      assert.equal(hasScrollableAncestor(nest(outer.container)), true)
      assert.equal(hasScrollableAncestor(nest(plain.container)), false)
    } finally {
      outer.unmount()
      plain.unmount()
    }
  })
})

describe('slot/invoke (§2)', () => {
  test('an action is called back by name, never shipped as a value', () => {
    const calls: unknown[][] = []
    const instance = rig()
    instance.render({ wide: true, expandSidebar: (...args: unknown[]) => { calls.push(args); return 'ok' } })
    const mount = instance.events('slot/mount')[0]
    assert.deepEqual(mount?.actions, ['expandSidebar'])
    // No function ever appears in the serialized envelope.
    assert.equal(JSON.stringify(mount).includes('=>'), false)

    const returned = instance.ledger.invoke({
      instanceId: instance.instanceId(),
      action: 'expandSidebar',
      args: ['from-native'],
    })
    assert.deepEqual(calls, [['from-native']])
    assert.equal(returned, 'ok')
  })

  test('the ledger always holds the current closure, not the mount-time one', () => {
    const seen: string[] = []
    const instance = rig()
    instance.render({ wide: true, expandSidebar: () => { seen.push('first') } })
    instance.render({ wide: true, expandSidebar: () => { seen.push('second') } })
    instance.ledger.invoke({ instanceId: instance.instanceId(), action: 'expandSidebar', args: [] })
    assert.deepEqual(seen, ['second'])
  })

  test('a mirrored instance exposes no injection face (§5)', () => {
    const instance = rig({ invocable: false })
    instance.render({ wide: true, expandSidebar: () => {} })
    assert.throws(
      () => instance.ledger.invoke({ instanceId: instance.instanceId(), action: 'expandSidebar', args: [] }),
      /slot_not_declared/,
    )
  })

  test('invoking an unmounted instance is slot_not_mounted', () => {
    const instance = rig()
    instance.render({ wide: true, expandSidebar: () => {} })
    const id = instance.instanceId()
    instance.harness.render(null)
    assert.throws(() => instance.ledger.invoke({ instanceId: id, action: 'expandSidebar', args: [] }), /slot_not_mounted/)
  })

  test('an unknown action name is unknown_method, and a wrong slot is bad_payload', () => {
    const instance = rig()
    instance.render({ wide: true, expandSidebar: () => {} })
    const id = instance.instanceId()
    assert.throws(() => instance.ledger.invoke({ instanceId: id, action: 'nope', args: [] }), /unknown_method/)
    assert.throws(
      () => instance.ledger.invoke({ instanceId: id, action: 'expandSidebar', args: [], slot: 'sidebar.settings' }),
      /bad_payload/,
    )
  })

  test('framework-installed function props are not invocable actions', () => {
    const actions = pickActions({
      expandSidebar: () => {},
      onPicked: () => {},
      renderSlot: () => {},
      renderSlotChain: () => {},
      SessionProvider: () => {},
      t: () => {},
      useWorkspaces: () => {},
      wide: true,
    })
    assert.deepEqual(Object.keys(actions), ['expandSidebar', 'onPicked'])
  })

  test('two keyed instances of one slot are tracked separately', () => {
    const first = rig({ key: 'left' })
    const second = rig({ key: 'right' })
    first.render({ wide: true, expandSidebar: () => {} })
    second.render({ wide: true, expandSidebar: () => {} })
    assert.notEqual(first.instanceId(), second.instanceId())
    assert.deepEqual(first.events('slot/mount')[0]?.key, 'left')
    assert.deepEqual(second.events('slot/mount')[0]?.key, 'right')
    assert.deepEqual(first.ledger.instancesOf(SLOT), [first.instanceId()])
  })
})
