/**
 * Control-channel tests — bridge-contract.md §1.2 (envelope), §1.3 (method
 * tables), §1.5 (timeout + closed error set), §4 (unknown `v` degrades).
 */

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import {
  BRIDGE_ERROR_CODES, BridgeFailure, CONFIGURE_TIMEOUT_MS, PROTOCOL_VERSION, REQUEST_TIMEOUT_MS,
  bridgeError, createBridge, decodeEnvelope, installReceiver, timeoutFor, webkitTransport,
  type ReceiverScope, type StudioGlobal, type WebkitScope,
} from '../src/client/bridge.ts'
import { createUlid } from '../src/client/ulid.ts'
import { manualTimers, recordingTransport } from './helpers.ts'

/** Envelope a native peer would send. */
const inbound = (body: Record<string, unknown>): string => JSON.stringify({ v: PROTOCOL_VERSION, ...body })

describe('envelope (§1.2)', () => {
  test('an event carries v/t/m/p and no id', () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.emit('slot/unmount', { instanceId: 'A' })
    assert.deepEqual(transport.sent, [{ v: 1, t: 'evt', m: 'slot/unmount', p: { instanceId: 'A' } }])
  })

  test('a request carries a ULID id and resolves on its receipt', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    const pending = bridge.request('slot/probe', { slot: 'x' })
    const sent = transport.sent[0]
    assert.equal(sent?.t, 'req')
    assert.match(String(sent?.id), /^[0-9A-HJKMNP-TV-Z]{26}$/)
    bridge.receive(inbound({ t: 'res', id: sent?.id, ok: true, p: { answered: true } }))
    assert.deepEqual(await pending, { answered: true })
  })

  test('a failing receipt rejects with the wire code', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    const pending = bridge.request('slot/invoke', {})
    bridge.receive(inbound({
      t: 'res', id: transport.sent[0]?.id, ok: false,
      e: { code: 'slot_not_mounted', message: 'gone', retryable: false },
    }))
    await assert.rejects(pending, (error: unknown) => {
      assert.ok(error instanceof BridgeFailure)
      assert.equal(error.code, 'slot_not_mounted')
      assert.equal(error.retryable, false)
      return true
    })
  })

  test('an error code outside the closed set is itself a protocol violation (§1.5)', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    const pending = bridge.request('slot/probe', {})
    bridge.receive(inbound({
      t: 'res', id: transport.sent[0]?.id, ok: false,
      e: { code: 'rate_limited', message: 'invented', retryable: true },
    }))
    await assert.rejects(pending, (error: unknown) => {
      assert.ok(error instanceof BridgeFailure)
      assert.equal(error.code, 'protocol_mismatch')
      return true
    })
  })

  test('the error set has exactly the seven documented codes', () => {
    assert.deepEqual([...BRIDGE_ERROR_CODES], [
      'unknown_method', 'bad_payload', 'protocol_mismatch',
      'slot_not_declared', 'slot_not_mounted', 'priority_conflict', 'internal',
    ])
  })

  test('decode rejects malformed shapes and never throws', () => {
    assert.equal(decodeEnvelope('{oops').kind, 'invalid')
    assert.equal(decodeEnvelope(42).kind, 'invalid')
    assert.equal(decodeEnvelope({ v: 1, t: 'req', m: 'x' }).kind, 'invalid')
    assert.equal(decodeEnvelope({ v: 1, t: 'req', id: 'a' }).kind, 'invalid')
    assert.equal(decodeEnvelope({ v: 1, t: 'req', id: 'a', m: 'x', p: [] }).kind, 'invalid')
    assert.equal(decodeEnvelope({ v: 1, t: 'res', id: 'a' }).kind, 'invalid')
    assert.equal(decodeEnvelope({ v: 1, t: 'nope', id: 'a' }).kind, 'invalid')
    assert.equal(decodeEnvelope({ v: 1, t: 'evt', m: 'slot/rect' }).kind, 'evt')
  })

  test('a malformed request with an id still gets a bad_payload receipt', () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.receive(inbound({ t: 'req', id: 'ID', p: {} }))
    assert.equal(transport.sent[0]?.ok, false)
    assert.equal(transport.sent[0]?.e?.code, 'bad_payload')
  })
})

describe('inbound dispatch (§1.3)', () => {
  test('a method outside the inbound table answers unknown_method', () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.receive(inbound({ t: 'req', id: 'ID', m: 'surface/teleport', p: {} }))
    assert.equal(transport.sent[0]?.e?.code, 'unknown_method')
  })

  test('a known method with no installed handler also answers unknown_method', () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.receive(inbound({ t: 'req', id: 'ID', m: 'slot/probe', p: {} }))
    assert.equal(transport.sent[0]?.e?.code, 'unknown_method')
  })

  test('a handler answers exactly one receipt, sync or async', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.handle('slot/probe', payload => ({ echo: payload.slot }))
    bridge.handle('slot/invoke', () => Promise.resolve({ returned: null }))
    bridge.receive(inbound({ t: 'req', id: 'A', m: 'slot/probe', p: { slot: 's' } }))
    bridge.receive(inbound({ t: 'req', id: 'B', m: 'slot/invoke', p: {} }))
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(transport.sent.map(envelope => [envelope.id, envelope.ok]), [['A', true], ['B', true]])
    assert.equal(transport.sent.length, 2)
  })

  test('a thrown BridgeFailure keeps its code; anything else is internal', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.handle('slot/probe', () => { throw bridgeError('bad_payload', 'no slot') })
    bridge.handle('slot/invoke', () => { throw new TypeError('boom') })
    bridge.receive(inbound({ t: 'req', id: 'A', m: 'slot/probe', p: {} }))
    bridge.receive(inbound({ t: 'req', id: 'B', m: 'slot/invoke', p: {} }))
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(transport.sent[0]?.e?.code, 'bad_payload')
    assert.equal(transport.sent[1]?.e?.code, 'internal')
    assert.match(String(transport.sent[1]?.e?.message), /boom/)
  })

  test('installing the same handler twice is a programming error', () => {
    const bridge = createBridge({ transport: recordingTransport() })
    bridge.handle('slot/probe', () => null)
    assert.throws(() => bridge.handle('slot/probe', () => null), /already installed/)
  })

  test('disposing a handler restores unknown_method', () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    const dispose = bridge.handle('slot/probe', () => 1)
    dispose()
    bridge.receive(inbound({ t: 'req', id: 'ID', m: 'slot/probe', p: {} }))
    assert.equal(transport.sent[0]?.e?.code, 'unknown_method')
  })

  test('an inbound evt is dropped: the contract has no inbound events', () => {
    const notes: string[] = []
    const bridge = createBridge({ transport: recordingTransport(), onDiagnostic: message => notes.push(message) })
    bridge.receive(inbound({ t: 'evt', m: 'slot/mount', p: {} }))
    assert.match(notes.join('\n'), /dropped inbound evt/)
  })
})

describe('timeout (§1.5)', () => {
  test('the budget is 5s, and 15s for surface/configure', () => {
    assert.equal(timeoutFor('slot/invoke'), REQUEST_TIMEOUT_MS)
    assert.equal(timeoutFor('surface/configure'), CONFIGURE_TIMEOUT_MS)
    assert.equal(REQUEST_TIMEOUT_MS, 5_000)
    assert.equal(CONFIGURE_TIMEOUT_MS, 15_000)
  })

  test('a timeout is terminal and is never retried', async () => {
    const transport = recordingTransport()
    const timers = manualTimers()
    const bridge = createBridge({ transport, timers })
    const pending = bridge.request('slot/probe', { slot: 'x' })
    assert.equal(timers.pending, 1)
    timers.advance(REQUEST_TIMEOUT_MS)
    await assert.rejects(pending, (error: unknown) => {
      assert.ok(error instanceof BridgeFailure)
      assert.equal(error.code, 'internal')
      assert.match(error.message, /timed out after 5000ms \(not retried\)/)
      return true
    })
    // Exactly one send: a retried orchestration message would double-mount.
    assert.equal(transport.sent.length, 1)
  })

  test('a receipt arriving after the timeout is dropped, not resurrected', async () => {
    const transport = recordingTransport()
    const timers = manualTimers()
    const notes: string[] = []
    const bridge = createBridge({ transport, timers, onDiagnostic: message => notes.push(message) })
    const pending = bridge.request('slot/probe', {})
    const id = String(transport.sent[0]?.id)
    timers.advance(REQUEST_TIMEOUT_MS)
    await pending.catch(() => undefined)
    bridge.receive(inbound({ t: 'res', id, ok: true, p: {} }))
    assert.match(notes.join('\n'), /dropped res for unknown id/)
  })

  test('a resolved request clears its timer', async () => {
    const transport = recordingTransport()
    const timers = manualTimers()
    const bridge = createBridge({ transport, timers })
    const pending = bridge.request('slot/probe', {})
    bridge.receive(inbound({ t: 'res', id: transport.sent[0]?.id, ok: true, p: 1 }))
    assert.equal(await pending, 1)
    assert.equal(timers.pending, 0)
  })
})

describe('unknown protocol version (§1.2, §4)', () => {
  test('an unknown v degrades the bridge once, without guessing', () => {
    const transport = recordingTransport()
    const seen: unknown[] = []
    const bridge = createBridge({ transport, onProtocolMismatch: version => seen.push(version) })
    bridge.receive(JSON.stringify({ v: 2, t: 'req', id: 'A', m: 'surface/configure', p: {} }))
    bridge.receive(JSON.stringify({ v: 2, t: 'req', id: 'B', m: 'surface/configure', p: {} }))
    assert.deepEqual(seen, [2])
    assert.equal(bridge.degraded, true)
  })

  test('a degraded bridge emits no further orchestration and starts no request', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.receive(JSON.stringify({ v: 99, t: 'evt', m: 'x' }))
    bridge.emit('slot/unmount', { instanceId: 'A' })
    assert.equal(transport.sent.length, 0)
    await assert.rejects(bridge.request('slot/probe', {}), /protocol_mismatch/)
  })

  test('a well-versioned request arriving after degradation still gets one honest receipt', () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.handle('slot/probe', () => ({ never: 'reached' }))
    bridge.receive(JSON.stringify({ v: 99, t: 'evt', m: 'x' }))
    bridge.receive(inbound({ t: 'req', id: 'after', m: 'slot/probe', p: {} }))
    // Silence would leave the host waiting out its own timeout; a
    // protocol_mismatch answer is the only thing that crosses (§1.5).
    assert.deepEqual(transport.sent.map(envelope => [envelope.id, envelope.e?.code]), [['after', 'protocol_mismatch']])
  })

  test('a malformed envelope after degradation is dropped, not answered', () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.receive(JSON.stringify({ v: 99, t: 'evt', m: 'x' }))
    bridge.receive(inbound({ t: 'req', id: 'broken' }))
    assert.deepEqual(transport.sent, [])
  })

  test('degrading rejects every in-flight request', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    const pending = bridge.request('surface/configure', {})
    bridge.receive(JSON.stringify({ v: 0, t: 'evt', m: 'x' }))
    await assert.rejects(pending, (error: unknown) => {
      assert.ok(error instanceof BridgeFailure)
      assert.equal(error.code, 'protocol_mismatch')
      return true
    })
  })
})

describe('transport plumbing (§1.1)', () => {
  test('the webkit transport is absent outside the Studio WebView', () => {
    assert.equal(webkitTransport({} as WebkitScope), undefined)
  })

  test('the webkit transport posts to the studio message handler', () => {
    const posted: string[] = []
    const scope: WebkitScope = {
      webkit: { messageHandlers: { studio: { postMessage: body => posted.push(body) } } },
    }
    webkitTransport(scope)?.post('{"a":1}')
    assert.deepEqual(posted, ['{"a":1}'])
  })

  test('the receiver global is reversible, as ctx.effect requires', () => {
    const previous: StudioGlobal = { protocol: 0, receive: () => {} }
    const scope: ReceiverScope = { __DSH_STUDIO__: previous }
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    bridge.handle('slot/probe', () => 'answered')
    const dispose = installReceiver(bridge, scope)
    assert.equal(scope.__DSH_STUDIO__?.protocol, PROTOCOL_VERSION)
    scope.__DSH_STUDIO__?.receive(inbound({ t: 'req', id: 'A', m: 'slot/probe', p: {} }))
    dispose()
    assert.equal(scope.__DSH_STUDIO__, previous)
  })
})

describe('ULID (§1.2)', () => {
  test('ids from one millisecond still sort in mint order', () => {
    const ulid = createUlid(() => 1_700_000_000_000)
    const minted = Array.from({ length: 64 }, () => ulid())
    assert.deepEqual(minted, [...minted].sort())
    assert.equal(new Set(minted).size, minted.length)
    for (const id of minted) assert.equal(id.length, 26)
  })

  test('a later millisecond sorts after an earlier one', () => {
    let now = 1_700_000_000_000
    const ulid = createUlid(() => now)
    const first = ulid()
    now += 1
    assert.ok(ulid() > first)
  })
})
