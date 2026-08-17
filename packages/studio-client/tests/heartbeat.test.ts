/**
 * Heartbeat tests — bridge-contract.md §1.6 / known-gaps.md G-3.
 *
 * The direction is the point of this file. The host (Swift) is the initiator:
 * it sends `req surface/ping { seq, sentAt }`, and this half answers. An
 * earlier revision of the client half had it backwards (Web emitting
 * `evt surface/ping`, native answering with a `req surface/pong`), which would
 * have left the real host — already shipped and tested — waiting for receipts
 * that never came and taking every native view down after two beats. The first
 * two tests below are therefore regression guards on the method tables
 * themselves, not decoration.
 */

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import {
  INBOUND_METHODS, OUTBOUND_EVENTS, PROTOCOL_VERSION, createBridge,
} from '../src/client/bridge.ts'
import {
  HEARTBEAT_INTERVAL_MS, HEARTBEAT_MISS_THRESHOLD, installHeartbeatResponder, readPing,
} from '../src/client/heartbeat.ts'
import { attachStudio } from '../src/client/index.ts'
import { fakeContext, recordingTransport, type RecordingTransport, type SentEnvelope } from './helpers.ts'

/** A ping as the host sends it. */
const ping = (seq: number, sentAt?: number): string => JSON.stringify({
  v: PROTOCOL_VERSION,
  t: 'req',
  id: `ping-${String(seq)}`,
  m: 'surface/ping',
  p: { seq, ...(sentAt === undefined ? {} : { sentAt }) },
})

/** The receipt of one ping id. */
const receipt = (transport: RecordingTransport, seq: number): SentEnvelope | undefined =>
  transport.sent.find(envelope => envelope.t === 'res' && envelope.id === `ping-${String(seq)}`)

/** Let the bridge's promise plumbing settle (a `res` always crosses a microtask). */
const flush = async (): Promise<void> => {
  await Promise.resolve()
  await Promise.resolve()
}

describe('direction (§1.6): the host pings, the client half answers', () => {
  test('surface/ping is an INBOUND method — the client half answers it', () => {
    assert.ok(INBOUND_METHODS.includes('surface/ping'))
    assert.ok(!(OUTBOUND_EVENTS as readonly string[]).includes('surface/ping'))
  })

  test('surface/pong is an OUTBOUND event — never a method the host must answer', () => {
    assert.ok(OUTBOUND_EVENTS.includes('surface/pong'))
    assert.ok(!(INBOUND_METHODS as readonly string[]).includes('surface/pong'))
  })

  test('the interval and miss threshold match the host implementation', () => {
    assert.equal(HEARTBEAT_INTERVAL_MS, 10_000)
    assert.equal(HEARTBEAT_MISS_THRESHOLD, 2)
  })
})

describe('payload narrowing (§5)', () => {
  test('a ping carries seq and an optional sentAt', () => {
    assert.deepEqual(readPing({ seq: 7, sentAt: 1_755_000_000 }), { seq: 7, sentAt: 1_755_000_000 })
    assert.deepEqual(readPing({ seq: 0 }), { seq: 0 })
  })

  test('a ping without a numeric seq is bad_payload, not a guessed beat', () => {
    for (const payload of [{}, { seq: '7' }, { seq: null }, { seq: Number.NaN }]) {
      assert.throws(() => readPing(payload), /bad_payload: "seq" must be a finite number/)
    }
  })

  test('a non-numeric sentAt is bad_payload too', () => {
    assert.throws(() => readPing({ seq: 1, sentAt: 'now' }), /bad_payload: "sentAt" must be a finite number/)
  })
})

describe('answering (§1.6)', () => {
  test('a ping is answered with a receipt echoing seq and sentAt', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    installHeartbeatResponder(bridge)
    bridge.receive(ping(7, 1_755_000_000))
    await flush()
    assert.deepEqual(receipt(transport, 7), {
      v: 1, t: 'res', id: 'ping-7', ok: true, p: { seq: 7, sentAt: 1_755_000_000 },
    })
  })

  test('seq is passed through verbatim, beat after beat', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    const responder = installHeartbeatResponder(bridge)
    for (const seq of [1, 2, 3, 41]) bridge.receive(ping(seq))
    await flush()
    assert.deepEqual(
      transport.sent.filter(envelope => envelope.t === 'res').map(envelope => envelope.p?.seq),
      [1, 2, 3, 41],
    )
    assert.equal(responder.answered, 4)
    assert.equal(responder.lastSeq, 41)
  })

  test('a ping without sentAt is answered with seq alone (no invented field)', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    installHeartbeatResponder(bridge)
    bridge.receive(ping(9))
    await flush()
    assert.deepEqual(receipt(transport, 9)?.p, { seq: 9 })
  })

  test('a malformed ping fails loud with bad_payload instead of a fake receipt', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    installHeartbeatResponder(bridge)
    bridge.receive(JSON.stringify({ v: PROTOCOL_VERSION, t: 'req', id: 'ping-x', m: 'surface/ping', p: {} }))
    await flush()
    const answer = transport.sent.find(envelope => envelope.id === 'ping-x')
    assert.equal(answer?.ok, false)
    assert.equal(answer?.e?.code, 'bad_payload')
  })

  test('the one-way form is available and carries the same seq', () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    const responder = installHeartbeatResponder(bridge)
    responder.volunteer(12)
    assert.deepEqual(transport.last('surface/pong'), { v: 1, t: 'evt', m: 'surface/pong', p: { seq: 12 } })
  })

  test('after disposal a ping answers unknown_method — which is why it stays installed', async () => {
    const transport = recordingTransport()
    const bridge = createBridge({ transport })
    installHeartbeatResponder(bridge).dispose()
    bridge.receive(ping(1))
    await flush()
    assert.equal(receipt(transport, 1)?.e?.code, 'unknown_method')
  })
})

describe('composition root', () => {
  test('attachStudio installs the responder, so the host gets a receipt without extra wiring', async () => {
    const ctx = fakeContext()
    const transport = recordingTransport()
    const studio = attachStudio(ctx, { transport, scope: {} })
    studio.bridge.receive(ping(3, 1_755_000_042))
    await flush()
    assert.deepEqual(receipt(transport, 3)?.p, { seq: 3, sentAt: 1_755_000_042 })
    assert.equal(studio.heartbeat.answered, 1)
    assert.equal(studio.heartbeat.lastSeq, 3)
    assert.ok(ctx.effects.includes('studio: surface/ping'))
  })

  test('plugin unload takes the answer down with everything else (the host then declares us lost, by design)', async () => {
    const ctx = fakeContext()
    const transport = recordingTransport()
    const studio = attachStudio(ctx, { transport, scope: {} })
    ctx.unload()
    transport.clear()
    studio.bridge.receive(ping(5))
    await flush()
    assert.equal(receipt(transport, 5)?.e?.code, 'unknown_method')
  })
})
