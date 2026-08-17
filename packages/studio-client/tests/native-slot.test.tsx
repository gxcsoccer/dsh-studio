/**
 * `NativeSlotProxy` tests — reference/native-slot-proxy.md §1 ("四件事"),
 * §2 (`slot/invoke`), ADR-0002 (whitelist) and ADR-0003 (overlay + scroll).
 *
 * `./dom.ts` must be imported before anything that pulls in react-dom.
 */

import assert from 'node:assert/strict'
import { afterEach, describe, test } from 'node:test'
import { act } from 'react'
import {
  dom, fakeResizeObservers, mountHarness, pinGeometry, pinHitTest,
  type Harness, type HarnessOptions,
} from './dom.ts'
import { createBridge, type Bridge } from '../src/client/bridge.ts'
import { createInstanceLedger, pickActions, type InstanceLedger } from '../src/client/invoke.ts'
import {
  ORCHESTRATION_KEYS, hasScrollableAncestor, isOccluded, nativeSlot, serializeOrchestration,
  shallowDiff, type NativeSlotOptions,
} from '../src/client/native-slot.tsx'
import { recordingTransport, type RecordingTransport, type SentEnvelope } from './helpers.ts'

const SLOT = 'sidebar.workspaces'

/** One assembled proxy under test. */
interface Rig {
  bridge: Bridge
  transport: RecordingTransport
  ledger: InstanceLedger
  harness: Harness
  /**
   * Render the proxy with the given props. Typed as a record because the whole
   * point of the proxy is that it accepts any owner share; the JSX spread is
   * what makes that legal against its narrow `ProxyProps` parameter.
   */
  render(props: Record<string, unknown>): void
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
  harnessOptions: HarnessOptions = {},
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
    render(props) { harness.render(<Component {...props} />) },
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
  /** jsdom's window is 1024×768; the proxy reports it as the CSS viewport. */
  const VIEWPORT = { w: 1_024, h: 768 }

  test('evacuated takes no screen area and reports no geometry', () => {
    const instance = rig({ placement: 'evacuated' })
    instance.render({ wide: true })
    assert.equal(instance.harness.proxyElement(SLOT)?.style.display, 'none')
    assert.deepEqual(instance.events('slot/rect'), [])
  })

  test('overlay reserves the cell with an invisible placeholder and reports its geometry', () => {
    const geometry = pinGeometry({ x: 12, y: 34, width: 260, height: 700 })
    try {
      const instance = rig({ placement: 'overlay' })
      instance.render({ wide: true })
      const element = instance.harness.proxyElement(SLOT)
      // `visibility: hidden`, never `display: none`: the box must stay in the
      // layout or the official parent's cell collapses and the native view has
      // no cell to fill (the W1 regression).
      assert.equal(element?.style.visibility, 'hidden')
      assert.notEqual(element?.style.display, 'none')
      // Stretch, not shrink-to-fit: a bare div in a flex column reports a 0px
      // tall rect, which is exactly how the first W1 build produced a 150px
      // sidebar that stopped in mid-air.
      assert.equal(element?.style.flex, '1 1 auto')
      assert.equal(element?.style.alignSelf, 'stretch')
      assert.deepEqual(instance.events('slot/rect'), [{
        instanceId: instance.instanceId(),
        rect: { x: 12, y: 34, w: 260, h: 700 },
        // Nothing clips here, so the clip box is the viewport itself.
        clip: { x: 0, y: 0, ...VIEWPORT },
        viewport: VIEWPORT,
        scrollable: false,
        occluded: false,
        dpr: 1,
      }])
    } finally {
      geometry.restore()
    }
  })

  test('a clipping (but not scrolling) ancestor narrows clip, not rect (G-1)', () => {
    // The official sidebar seat is `overflow: hidden`. Reporting that as
    // `scrollable` gets the cell refused under ADR-0003 (no native rail at
    // all); reporting it as nothing at all lets the native view spill over the
    // conversation while the column animates. It is a third fact, so it gets
    // its own field — and it must narrow `clip` only, never `rect`: the view is
    // laid out at its full size and merely masked.
    const observers = fakeResizeObservers()
    const geometry = pinGeometry({ x: 0, y: 52, width: 260, height: 800 })
    try {
      const instance = rig({ placement: 'overlay' }, { clipping: true })
      instance.render({ wide: true })
      // The clipping ancestor reports a shorter box than the cell: the bottom
      // 300px is cut off. It lands on the *second* measurement because the pin
      // is per-element and the container only exists once the harness is up.
      geometry.setFor(instance.harness.container, { x: 0, y: 52, width: 260, height: 500 })
      observers.trigger()
      const payload = instance.events('slot/rect')[1]
      assert.deepEqual(payload?.rect, { x: 0, y: 52, w: 260, h: 800 })
      assert.deepEqual(payload?.clip, { x: 0, y: 52, w: 260, h: 500 })
      assert.equal(payload?.scrollable, false)
    } finally {
      geometry.restore()
      observers.restore()
    }
  })

  test('a resize re-measures through ResizeObserver, not a polling loop', () => {
    const observers = fakeResizeObservers()
    const geometry = pinGeometry({ x: 0, y: 0, width: 100, height: 100 })
    try {
      const instance = rig({ placement: 'overlay' })
      instance.render({ wide: true })
      assert.equal(observers.observed, 1)

      // An unchanged geometry is not forwarded: these observers fire on every
      // frame of every scroll and resize in the document, and a control channel
      // full of identical rects hides the events that matter.
      observers.trigger()
      assert.equal(instance.events('slot/rect').length, 1)

      geometry.set({ x: 0, y: 0, width: 100, height: 420 })
      observers.trigger()
      assert.equal(instance.events('slot/rect').length, 2)
      assert.deepEqual(instance.events('slot/rect')[1]?.rect, { x: 0, y: 0, w: 100, h: 420 })

      instance.harness.render(null)
      assert.equal(observers.disconnected, 1)
    } finally {
      geometry.restore()
      observers.restore()
    }
  })

  test('an ancestor scroll re-measures too (capture, since scroll does not bubble)', () => {
    const geometry = pinGeometry({ x: 0, y: 0, width: 100, height: 100 })
    try {
      const instance = rig({ placement: 'overlay' })
      instance.render({ wide: true })
      geometry.set({ x: 0, y: -40, width: 100, height: 100 })
      act(() => {
        instance.harness.container.dispatchEvent(new dom.window.Event('scroll'))
      })
      assert.deepEqual(instance.events('slot/rect')[1]?.rect, { x: 0, y: -40, w: 100, h: 100 })
    } finally {
      geometry.restore()
    }
  })

  test('a fully covered cell reports occluded: the Web overlay wins (G-1)', () => {
    // A native subview of the WKWebView cannot be painted under a Web modal
    // scrim, so a covered cell must withdraw instead of floating on top of it.
    const geometry = pinGeometry({ x: 0, y: 0, width: 260, height: 700 })
    const scrim = dom.window.document.createElement('div')
    dom.window.document.body.appendChild(scrim)
    const restoreHitTest = pinHitTest(scrim)
    try {
      const instance = rig({ placement: 'overlay' })
      instance.render({ wide: true })
      assert.equal(instance.events('slot/rect')[0]?.occluded, true)
    } finally {
      restoreHitTest()
      geometry.restore()
      scrim.remove()
    }
  })

  test('isOccluded samples every corner, and never counts the cell\'s own lineage', () => {
    const harness = mountHarness()
    const leaf = harness.container.ownerDocument.createElement('div')
    harness.container.appendChild(leaf)
    const box = { x: 0, y: 0, w: 260, h: 700 }
    try {
      // The placeholder is `visibility: hidden` and is therefore never hit
      // itself: a bare cell resolves to its nearest visible ancestor. Counting
      // that as occlusion would blank the native view permanently.
      const restoreAncestor = pinHitTest(harness.container)
      assert.equal(isOccluded(leaf, box), false)
      restoreAncestor()

      const foreign = harness.container.ownerDocument.createElement('div')
      const restoreForeign = pinHitTest(foreign)
      assert.equal(isOccluded(leaf, box), true)
      // A box too small to sample meaningfully resolves toward visible: unknown
      // must never mean "hide the native view".
      assert.equal(isOccluded(leaf, { x: 0, y: 0, w: 1, h: 1 }), false)
      restoreForeign()

      // No `elementFromPoint` at all (jsdom's default) is also "visible".
      assert.equal(isOccluded(leaf, box), false)
    } finally {
      harness.unmount()
    }
  })

  test('a scroll container ancestor is reported honestly (ADR-0003)', () => {
    const geometry = pinGeometry({ x: 0, y: 0, width: 10, height: 10 })
    try {
      const instance = rig({ placement: 'overlay' }, { scrollable: true })
      instance.render({ wide: true })
      assert.equal(instance.events('slot/rect')[0]?.scrollable, true)
    } finally {
      geometry.restore()
    }
  })

  test('dpr is reported for diagnostics only, and never as the px→point scale', () => {
    // Retina is dpr 2 while CSS px and points stay 1:1. Using dpr as the scale
    // makes the native view exactly twice too big — the classic version of this
    // bug, so the wire keeps the two numbers apart: `viewport` drives the
    // scale, `dpr` is a log line.
    const geometry = pinGeometry({ x: 0, y: 0, width: 260, height: 700 })
    const view = dom.window as unknown as Record<string, unknown>
    const previous = view.devicePixelRatio
    Object.defineProperty(view, 'devicePixelRatio', { value: 2, configurable: true })
    try {
      const instance = rig({ placement: 'overlay' })
      instance.render({ wide: true })
      const payload = instance.events('slot/rect')[0]
      assert.equal(payload?.dpr, 2)
      assert.deepEqual(payload?.viewport, VIEWPORT)
    } finally {
      Object.defineProperty(view, 'devicePixelRatio', { value: previous, configurable: true })
      geometry.restore()
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
