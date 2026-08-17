/**
 * Liveness — the **answering** half of the runtime heartbeat
 * (bridge-contract.md §1.6, known-gaps.md G-3).
 *
 * Direction is not symmetric, and it is not an implementation detail: the
 * **host is the initiator**. It sends `req surface/ping { seq, sentAt }` every
 * 10s, and two consecutive unanswered beats mean this half died silently — a
 * stuck event loop, a reclaimed page, a plugin that threw during a re-render.
 * The host's response is to take every native slot view down so the official
 * Web UI (still registered underneath, ADR-0004) renders again.
 *
 * Why the host supervises instead of the client:
 *   - the failure the heartbeat exists to catch is *this* half going silent,
 *     and a dead event loop cannot report itself;
 *   - a native view still on screen with a dead `slot/invoke` path is the worst
 *     possible state — the user can click and nothing answers, which is worse
 *     than a blank panel.
 *
 * So all this module owns is the answer: install one inbound handler that
 * echoes `seq` back. There is no timer here, no `lost` state, no takedown
 * policy — those live in the host (`SurfaceHeartbeat.swift`), which is the only
 * side that can act on them.
 */

import { bridgeError, type Bridge } from './bridge.ts'

/** Heartbeat interval the host drives, in milliseconds (§1.6). Mirrored here for documentation and tests. */
export const HEARTBEAT_INTERVAL_MS = 10_000

/** Consecutive unanswered beats after which the host declares this half lost (§1.6). */
export const HEARTBEAT_MISS_THRESHOLD = 2

/** What one `surface/ping` carries (§1.3, Native → Web). */
export interface PingPayload {
  /** Beat counter, monotonic per host session. */
  seq: number
  /** Host clock when the beat was sent (epoch seconds). Echoed, never interpreted. */
  sentAt?: number
}

/** The receipt this half answers a ping with (§1.3). */
export interface PongPayload {
  seq: number
  /** Echoed unchanged when the ping carried it, so the host can measure a round trip. */
  sentAt?: number
}

/** Observable state of the answering half; read by tests and diagnostics only. */
export interface HeartbeatResponder {
  /** Beats answered since install. */
  readonly answered: number
  /** `seq` of the most recent answered beat, or undefined before the first. */
  readonly lastSeq: number | undefined
  /**
   * Answer a beat out of band, as `evt surface/pong`. The host counts it as
   * liveness evidence just like a receipt; nothing in the client half needs it
   * today, and it exists because the host explicitly accepts both forms.
   * @param seq - beat counter to echo.
   */
  volunteer(seq: number): void
}

/**
 * Narrow a ping payload (§5: inbound payloads are untrusted).
 * @param payload - raw inbound payload.
 * @returns the narrowed ping.
 * @throws BridgeFailure `bad_payload` when `seq` is not a finite number.
 */
export function readPing(payload: Record<string, unknown>): PingPayload {
  const seq = payload.seq
  if (typeof seq !== 'number' || !Number.isFinite(seq)) {
    throw bridgeError('bad_payload', '"seq" must be a finite number')
  }
  const sentAt = payload.sentAt
  if (sentAt !== undefined && (typeof sentAt !== 'number' || !Number.isFinite(sentAt))) {
    throw bridgeError('bad_payload', '"sentAt" must be a finite number when present')
  }
  return { seq, ...(sentAt === undefined ? {} : { sentAt }) }
}

/**
 * Install the `surface/ping` answer.
 *
 * The handler is deliberately trivial and allocation-cheap: answering IS the
 * liveness proof, so anything it did beyond echoing would only add ways to
 * fail. It must also stay installed for the whole lifetime of the client half —
 * an uninstalled handler answers `unknown_method`, which the host reads as a
 * miss and (twice over) as death.
 * @param bridge - the control channel.
 * @param onBeat - optional diagnostics sink, called with each answered beat.
 * @returns the responder face; disposing is the caller's `ctx.effect`.
 */
export function installHeartbeatResponder(
  bridge: Bridge,
  onBeat?: (seq: number) => void,
): HeartbeatResponder & { dispose(): void } {
  let answered = 0
  let lastSeq: number | undefined

  const remove = bridge.handle('surface/ping', (payload): PongPayload => {
    const ping = readPing(payload)
    answered += 1
    lastSeq = ping.seq
    onBeat?.(ping.seq)
    // Echo, nothing else. `sentAt` rides back so the host can measure the round
    // trip without keeping its own send table.
    return { seq: ping.seq, ...(ping.sentAt === undefined ? {} : { sentAt: ping.sentAt }) }
  })

  return {
    get answered() { return answered },
    get lastSeq() { return lastSeq },
    volunteer(seq) { bridge.emit('surface/pong', { seq }) },
    dispose: remove,
  }
}
