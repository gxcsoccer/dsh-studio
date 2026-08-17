/**
 * Composition-root tests — the handshake (bridge-contract.md §1.1), the inbound
 * method table (§1.3), `slot/error` telemetry, the protocol-mismatch fallback
 * (§4 / ADR-0004) and plugin-unload reversibility.
 *
 * No DOM here on purpose: registering a proxy does not render it, so these
 * tests exercise the wiring against the fake slot registry only.
 */

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import type { LiveSlotNode } from '@deepseek-ai/dsh-client-ui-slots'
import { PROTOCOL_VERSION, type WebkitScope, type ReceiverScope } from '../src/client/bridge.ts'
import { REGISTRANT, apply, attachStudio, surveySlots, type ProbeResult } from '../src/client/index.ts'
import { SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW } from '../src/client/slots/index.ts'
import { fakeContext, fakeSlots, recordingTransport, type FakeContext, type FakeSlots, type RecordingTransport, type SentEnvelope } from './helpers.ts'

/** Let the bridge's promise plumbing settle (a `res` always crosses a microtask). */
const flush = async (): Promise<void> => {
  await Promise.resolve()
  await Promise.resolve()
}

/** An assembled client half over a fake registry. */
interface Rig {
  ctx: FakeContext
  slots: FakeSlots
  transport: RecordingTransport
  scope: ReceiverScope
  studio: ReturnType<typeof attachStudio>
  /** Deliver an inbound `req` and return its id. */
  send(method: string, payload: Record<string, unknown>): string
  /** The `res` of one request id. */
  answer(id: string): SentEnvelope | undefined
}

let requestCounter = 0

/**
 * Assemble the client half.
 * @param slots - registry double (defaults to the official W1 world).
 * @returns the rig.
 */
function rig(slots: FakeSlots = officialWorld()): Rig {
  const ctx = fakeContext(slots)
  const transport = recordingTransport()
  const scope: ReceiverScope = {}
  const studio = attachStudio(ctx, { transport, scope })
  return {
    ctx,
    slots,
    transport,
    scope,
    studio,
    send(method, payload) {
      requestCounter += 1
      const id = `req-${requestCounter}`
      studio.bridge.receive(JSON.stringify({ v: PROTOCOL_VERSION, t: 'req', id, m: method, p: payload }))
      return id
    },
    answer(id) {
      return transport.sent.find(envelope => envelope.t === 'res' && envelope.id === id)
    },
  }
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

describe('the measured slot table', () => {
  test('a snapshot tree is flattened depth-first and sorted by name', () => {
    const tree: LiveSlotNode[] = [{
      name: 'sidebar',
      kind: 'single',
      scope: 'root',
      occupants: [{ priority: 0, active: true, registrant: 'ui-sidebar' }],
      children: [{
        name: 'sidebar.workspaces',
        kind: 'single',
        scope: 'root',
        occupants: [
          { priority: -1, active: true, registrant: REGISTRANT },
          { priority: 0, active: false, registrant: 'ui-workspace' },
        ],
        children: [],
      }],
    }]
    assert.deepEqual(surveySlots(tree).map(row => row.name), ['sidebar', 'sidebar.workspaces'])
    assert.deepEqual(surveySlots(tree)[1]?.occupants, [
      { priority: -1, active: true, registrant: REGISTRANT },
      { priority: 0, active: false, registrant: 'ui-workspace' },
    ])
  })

  test('the handshake reports what this build has, not what the pins believe', () => {
    const instance = rig()
    instance.studio.announce()
    const ready = instance.transport.last('surface/ready')
    assert.equal(ready?.p?.protocol, PROTOCOL_VERSION)
    const rows = ready?.p?.slots as Array<{ name: string; occupants: unknown[] }>
    assert.deepEqual(rows.map(row => row.name), ['sidebar', SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_DIRECTORY_FLOW])
    assert.deepEqual(rows[1]?.occupants, [{ priority: 0, active: true, registrant: 'ui-workspace' }])
  })
})

describe('surface/configure', () => {
  test('a native row registers below the official entry and wins the cell', async () => {
    const instance = rig()
    const id = instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    await flush()
    assert.equal(instance.answer(id)?.ok, true)
    assert.deepEqual(instance.answer(id)?.p?.applied, [SIDEBAR_WORKSPACES])
    assert.deepEqual(instance.answer(id)?.p?.rejected, [])

    const ledgerRows = instance.slots.cell(SIDEBAR_WORKSPACES)
    assert.deepEqual(
      ledgerRows.map(entry => [entry.options.priority, entry.registrant]),
      [[-1, REGISTRANT], [0, 'ui-workspace']],
    )
    // Upstream renders the lowest priority: ours.
    assert.equal(instance.slots.entriesOfSlot(SIDEBAR_WORKSPACES)[0]?.registrant, REGISTRANT)
    // The official entry is untouched — that is the fallback (ADR-0004).
    assert.equal(instance.slots.spec(SIDEBAR_WORKSPACES_DIRECTORY_FLOW) !== undefined, true)
  })

  test('registration is one effect per cell, labelled by the cell', () => {
    const instance = rig()
    instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    assert.ok(instance.ctx.effects.includes(`studio: ${SIDEBAR_WORKSPACES}`))
  })

  test('a configure that arrives before the declaring plugin loaded still applies later', async () => {
    const slots = fakeSlots()
    const instance = rig(slots)
    const id = instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    await flush()
    const result = instance.answer(id)?.p as { applied: string[]; notes: string[] }
    assert.deepEqual(result.applied, [SIDEBAR_WORKSPACES])
    assert.match(result.notes.join('\n'), /registration is deferred/)
    assert.equal(slots.all.length, 0)

    // ui-sidebar loads and declares the hole: `ctx.slots.inject` fires.
    slots.declare(SIDEBAR_WORKSPACES, { kind: 'single', scope: 'root' })
    assert.deepEqual(slots.all.map(entry => [entry.slot, entry.registrant]), [[SIDEBAR_WORKSPACES, REGISTRANT]])
  })

  test('an unknown slot is rejected without touching anything else', async () => {
    const instance = rig()
    const id = instance.send('surface/configure', {
      manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' }, 'sidebar.ghost': { mode: 'native' } },
    })
    await flush()
    const result = instance.answer(id)?.p as { applied: string[]; rejected: Array<{ cell: string; reason: string }> }
    assert.deepEqual(result.applied, [SIDEBAR_WORKSPACES])
    assert.deepEqual(result.rejected.map(rejection => [rejection.cell, rejection.reason]), [['sidebar.ghost', 'slot_not_declared']])
  })

  test('a malformed manifest is a rejection inside a successful receipt, not a crash', async () => {
    const instance = rig()
    const id = instance.send('surface/configure', { manifest: 'not-an-object' })
    await flush()
    assert.equal(instance.answer(id)?.ok, true)
    assert.deepEqual((instance.answer(id)?.p as { rejected: Array<{ reason: string }> }).rejected.map(r => r.reason), ['bad_payload'])
  })
})

describe('surface/reconfigure', () => {
  test('switching a cell back to web frees it at runtime, with no reload', async () => {
    const instance = rig()
    instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    await flush()
    const id = instance.send('surface/reconfigure', { patch: { [SIDEBAR_WORKSPACES]: { mode: 'web' } } })
    await flush()
    assert.equal(instance.answer(id)?.ok, true)
    assert.deepEqual(instance.slots.cell(SIDEBAR_WORKSPACES).map(entry => entry.registrant), ['ui-workspace'])
    assert.deepEqual(instance.studio.controller.active, [])
    assert.equal(instance.ctx.effects.includes(`studio: ${SIDEBAR_WORKSPACES}`), false)
  })

  test('switching straight back re-takes the same cell at the same priority', async () => {
    const instance = rig()
    instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    await flush()
    instance.send('surface/reconfigure', { patch: { [SIDEBAR_WORKSPACES]: { mode: 'web' } } })
    await flush()
    const id = instance.send('surface/reconfigure', { patch: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    await flush()
    assert.deepEqual((instance.answer(id)?.p as { applied: string[] }).applied, [SIDEBAR_WORKSPACES])
    assert.deepEqual(instance.slots.cell(SIDEBAR_WORKSPACES).map(entry => entry.options.priority), [-1, 0])
  })
})

describe('slot/invoke over the wire', () => {
  test('a mounted instance answers with its return value', async () => {
    const instance = rig()
    const release = instance.studio.ledger.mount('01INSTANCE', {
      slot: SIDEBAR_WORKSPACES,
      invocable: true,
      actions: { expandSidebar: () => 'expanded' },
    })
    const id = instance.send('slot/invoke', { instanceId: '01INSTANCE', action: 'expandSidebar', args: [] })
    await flush()
    assert.deepEqual(instance.answer(id)?.p, { returned: 'expanded' })
    release()
  })

  test('an unmounted instance is a closed-set failure receipt', async () => {
    const instance = rig()
    const id = instance.send('slot/invoke', { instanceId: 'gone', action: 'expandSidebar', args: [] })
    await flush()
    assert.equal(instance.answer(id)?.ok, false)
    assert.equal(instance.answer(id)?.e?.code, 'slot_not_mounted')
    assert.equal(instance.answer(id)?.e?.retryable, false)
  })

  test('a payload without an action name is bad_payload', async () => {
    const instance = rig()
    const id = instance.send('slot/invoke', { instanceId: 'x' })
    await flush()
    assert.equal(instance.answer(id)?.e?.code, 'bad_payload')
  })
})

describe('slot/probe', () => {
  test('it answers with the live occupancy, our cells, and our instances', async () => {
    const instance = rig()
    instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    instance.studio.ledger.mount('01PROBE', { slot: SIDEBAR_WORKSPACES, invocable: true, actions: {} })
    const id = instance.send('slot/probe', { slot: SIDEBAR_WORKSPACES })
    await flush()
    const probe = instance.answer(id)?.p as unknown as ProbeResult
    assert.equal(probe.declared, true)
    assert.equal(probe.kind, 'single')
    assert.deepEqual(probe.occupants.map(occupant => occupant.priority), [-1, 0])
    assert.deepEqual(probe.studioCells, [SIDEBAR_WORKSPACES])
    assert.deepEqual(probe.instances, ['01PROBE'])
  })

  test('an undeclared slot answers declared:false instead of failing', async () => {
    const instance = rig()
    const id = instance.send('slot/probe', { slot: 'sidebar.ghost' })
    await flush()
    const probe = instance.answer(id)?.p as unknown as ProbeResult
    assert.deepEqual(probe, { slot: 'sidebar.ghost', declared: false, occupants: [], instances: [], studioCells: [] })
  })
})

describe('the closed method table (§1.3)', () => {
  test('a method outside the table is unknown_method', async () => {
    const instance = rig()
    const id = instance.send('surface/teardown', {})
    await flush()
    assert.equal(instance.answer(id)?.e?.code, 'unknown_method')
  })

  test('a malformed envelope gets a bad_payload receipt when it has an id', () => {
    const instance = rig()
    instance.studio.bridge.receive(JSON.stringify({ v: PROTOCOL_VERSION, t: 'req', id: 'x1' }))
    assert.equal(instance.answer('x1')?.e?.code, 'bad_payload')
  })
})

describe('slot/error telemetry (§1.3)', () => {
  test('a render failure is reported with the instance and the abdication flag', () => {
    const instance = rig()
    instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    instance.studio.ledger.mount('01ERR', { slot: SIDEBAR_WORKSPACES, invocable: true, actions: {} })
    const entry = instance.slots.cell(SIDEBAR_WORKSPACES)[0]
    assert.ok(entry !== undefined)
    instance.slots.emitEntryError(SIDEBAR_WORKSPACES, entry, new Error('boom'), { abdicated: true })
    assert.deepEqual(instance.transport.last('slot/error')?.p, {
      slot: SIDEBAR_WORKSPACES,
      instanceId: '01ERR',
      error: 'boom',
      abdicated: true,
    })
  })

  test('an ambiguous slot omits the instanceId instead of guessing', () => {
    const instance = rig()
    instance.studio.ledger.mount('01A', { slot: SIDEBAR_WORKSPACES, invocable: true, actions: {} })
    instance.studio.ledger.mount('01B', { slot: SIDEBAR_WORKSPACES, invocable: true, actions: {} })
    const entry = instance.slots.cell(SIDEBAR_WORKSPACES)[0]
    assert.ok(entry !== undefined)
    instance.slots.emitEntryError(SIDEBAR_WORKSPACES, entry, 'string failure', { abdicated: false })
    const payload = instance.transport.last('slot/error')?.p
    assert.equal('instanceId' in (payload ?? {}), false)
    assert.equal(payload?.error, 'string failure')
  })
})

describe('protocol mismatch (§4, ADR-0004)', () => {
  test('an unknown v releases every cell and silences the channel', async () => {
    const instance = rig()
    instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    await flush()
    assert.equal(instance.studio.controller.active.length, 1)

    instance.studio.bridge.receive(JSON.stringify({ v: 99, t: 'evt', m: 'surface/hello', p: {} }))
    assert.equal(instance.studio.bridge.degraded, true)
    assert.deepEqual(instance.studio.controller.active, [])
    // The official occupant is alone in the cell again: pure Web fallback.
    assert.deepEqual(instance.slots.cell(SIDEBAR_WORKSPACES).map(entry => entry.registrant), ['ui-workspace'])

    instance.transport.clear()
    instance.studio.announce()
    assert.deepEqual(instance.transport.sent, [])
  })

  test('a request arriving after degradation gets a protocol_mismatch receipt', () => {
    const instance = rig()
    instance.studio.bridge.receive(JSON.stringify({ v: 2, t: 'res', id: 'whatever', ok: true }))
    const id = instance.send('slot/probe', { slot: SIDEBAR_WORKSPACES })
    assert.equal(instance.answer(id)?.e?.code, 'protocol_mismatch')
  })
})

describe('reversibility', () => {
  test('unloading the plugin removes the global, the handlers and the registrations', async () => {
    const instance = rig()
    instance.send('surface/configure', { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } })
    await flush()
    assert.equal(instance.scope.__DSH_STUDIO__?.protocol, PROTOCOL_VERSION)

    instance.ctx.unload()
    await flush()
    assert.equal(instance.scope.__DSH_STUDIO__, undefined)
    assert.deepEqual(instance.slots.cell(SIDEBAR_WORKSPACES).map(entry => entry.registrant), ['ui-workspace'])
    assert.deepEqual(instance.ctx.effects, [])
  })
})

describe('the plugin entry point', () => {
  test('a page without the WKWebView handler stays inert', () => {
    const ctx = fakeContext(officialWorld())
    apply(ctx)
    assert.deepEqual(ctx.effects, [])
    assert.equal((globalThis as unknown as ReceiverScope).__DSH_STUDIO__, undefined)
  })

  test('inside the WKWebView it installs the receiver and announces itself', async () => {
    const posted: string[] = []
    const scope = globalThis as unknown as WebkitScope & ReceiverScope
    scope.webkit = { messageHandlers: { studio: { postMessage: (body: string) => { posted.push(body) } } } }
    try {
      const ctx = fakeContext(officialWorld())
      apply(ctx, { diagnostics: false })
      assert.equal(scope.__DSH_STUDIO__?.protocol, PROTOCOL_VERSION)
      const ready = JSON.parse(posted[0] ?? '{}') as SentEnvelope
      assert.equal(ready.m, 'surface/ready')

      // The receiver is the host's only entry point, and it works.
      scope.__DSH_STUDIO__?.receive(JSON.stringify({
        v: PROTOCOL_VERSION, t: 'req', id: 'live-1', m: 'surface/configure',
        p: { manifest: { [SIDEBAR_WORKSPACES]: { mode: 'native' } } },
      }))
      await flush()
      const receipt = posted.map(json => JSON.parse(json) as SentEnvelope).find(envelope => envelope.id === 'live-1')
      assert.deepEqual(receipt?.p?.applied, [SIDEBAR_WORKSPACES])

      ctx.unload()
      await flush()
      assert.equal(scope.__DSH_STUDIO__, undefined)
    } finally {
      delete scope.webkit
    }
  })
})
