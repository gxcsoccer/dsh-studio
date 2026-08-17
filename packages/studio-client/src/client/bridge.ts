/**
 * Control channel — the Web half of bridge-contract.md §1.
 *
 * Transport (§1.1):
 *   Web  → Native  `window.webkit.messageHandlers.studio.postMessage(json)`
 *   Native → Web   `window.__DSH_STUDIO__.receive(json)`
 *
 * This module owns the envelope (§1.2), the closed method tables (§1.3), and
 * the timeout/error semantics (§1.5). It carries **orchestration only**: no
 * domain entity is allowed through here (ADR-0002), which is why no payload
 * type below names a session, message, or workspace.
 */

import { createUlid, type UlidFactory } from './ulid.ts'

/** Wire protocol version (§1.2). Bumped only on incompatible change (§4). */
export const PROTOCOL_VERSION = 1

/** Closed error-code set (§1.5). A code outside this list is a protocol violation. */
export const BRIDGE_ERROR_CODES = [
  'unknown_method',
  'bad_payload',
  'protocol_mismatch',
  'slot_not_declared',
  'slot_not_mounted',
  'priority_conflict',
  'internal',
] as const

/** One of the seven codes in the closed set (§1.5). */
export type BridgeErrorCode = (typeof BRIDGE_ERROR_CODES)[number]

/** Wire error object (`e` member of a failing `res`). */
export interface WireError {
  code: BridgeErrorCode
  message: string
  retryable: false
}

/** Error carrying a wire code, so a handler rejection maps onto `e` without guessing. */
export class BridgeFailure extends Error {
  readonly code: BridgeErrorCode
  /**
   * Always `false`: the contract has no retryable failure — a retried
   * orchestration message would double-mount (§1.5).
   */
  readonly retryable = false as const

  /**
   * @param code - closed-set error code.
   * @param message - human-readable cause.
   */
  constructor(code: BridgeErrorCode, message: string) {
    super(`${code}: ${message}`)
    this.name = 'BridgeFailure'
    this.code = code
  }

  /** @returns the wire form of this failure. */
  toWire(): WireError {
    return { code: this.code, message: this.message, retryable: false }
  }
}

/**
 * Mint a {@link BridgeFailure}.
 * @param code - closed-set error code.
 * @param message - human-readable cause.
 * @returns the failure, ready to throw.
 */
export function bridgeError(code: BridgeErrorCode, message: string = code): BridgeFailure {
  return new BridgeFailure(code, message)
}

/** Native → Web request methods (§1.3, first table). */
export const INBOUND_METHODS = [
  'surface/configure',
  'surface/reconfigure',
  'surface/ping',
  'slot/invoke',
  'slot/probe',
] as const

/** A method the Web half answers. */
export type InboundMethod = (typeof INBOUND_METHODS)[number]

/** Web → Native event methods (§1.3, second table). */
export const OUTBOUND_EVENTS = [
  'surface/ready',
  'surface/pong',
  'slot/mount',
  'slot/props',
  'slot/rect',
  'slot/unmount',
  'slot/error',
] as const

/** A one-way notification the Web half sends. */
export type OutboundEvent = (typeof OUTBOUND_EVENTS)[number]

/** Slot scope as reported to the host (mirrors upstream `SlotScope`). */
export type WireScope = 'root' | 'session-maybe' | 'session'

/** One row of the measured slot table in `surface/ready`. */
export interface SurveyedSlot {
  name: string
  kind: 'single' | 'list' | 'keyed' | 'chain'
  scope: WireScope
  /** Current occupants in ledger order: who holds which priority, and who renders. */
  occupants: Array<{ priority: number; registrant?: string; key?: string; id?: string; active: boolean }>
}

/** Geometry of an overlay placement (CSS pixels, viewport coordinates). */
export interface WireRect { x: number; y: number; w: number; h: number }

/** Payload of each outbound event (§1.3). */
export interface OutboundEventPayloads {
  'surface/ready': { protocol: number; slots: SurveyedSlot[] }
  /**
   * Liveness answer (§1.6). The **host** is the heartbeat's initiator: it sends
   * `req surface/ping` every 10s and this half answers. The receipt of that
   * request is the primary answer; this event is the equivalent one-way form the
   * host also accepts, so a client half that wants to volunteer liveness
   * outside a ping can do it without inventing a method. `seq` is echoed
   * verbatim — the host uses it to notice an answer to an older beat.
   */
  'surface/pong': { seq: number }
  'slot/mount': {
    slot: string
    instanceId: string
    key?: string
    scope: WireScope
    props: Record<string, unknown>
    /** Names only — the functions stay on the Web side (reference §2). */
    actions: string[]
  }
  'slot/props': { instanceId: string; props: Record<string, unknown> }
  'slot/rect': { instanceId: string; rect: WireRect; scrollable: boolean }
  'slot/unmount': { instanceId: string }
  'slot/error': { slot: string; instanceId?: string; error: string; abdicated: boolean }
}

/** Request timeout budget in milliseconds (§1.5). */
export const REQUEST_TIMEOUT_MS = 5_000
/** `surface/configure` gets a longer budget (§1.5). */
export const CONFIGURE_TIMEOUT_MS = 15_000

/**
 * Timeout budget of a method.
 * @param method - method name.
 * @returns the budget in milliseconds.
 */
export function timeoutFor(method: string): number {
  return method === 'surface/configure' ? CONFIGURE_TIMEOUT_MS : REQUEST_TIMEOUT_MS
}

/** Web → Native transport seam (`postMessage` in production, a spy in tests). */
export interface BridgeTransport {
  post(json: string): void
}

/** Timer seam so timeout behaviour is testable without wall-clock waits. */
export interface TimerSeam {
  setTimeout(handler: () => void, ms: number): unknown
  clearTimeout(handle: unknown): void
}

const REAL_TIMERS: TimerSeam = {
  setTimeout: (handler, ms) => setTimeout(handler, ms),
  clearTimeout: (handle) => { clearTimeout(handle as ReturnType<typeof setTimeout>) },
}

/** Inbound request handler. Payload arrives unvalidated — handlers narrow it themselves (§5). */
export type InboundHandler = (payload: Record<string, unknown>) => unknown

/** The control channel face consumed by the rest of the client half. */
export interface Bridge {
  /** Send a one-way notification (§1.3, Web → Native). */
  emit<K extends OutboundEvent>(method: K, payload: OutboundEventPayloads[K]): void
  /**
   * Send a request and await its receipt. Times out per {@link timeoutFor} and
   * **never retries** (§1.5).
   */
  request(method: string, payload: Record<string, unknown>, options?: { timeoutMs?: number }): Promise<unknown>
  /** Install the handler of an inbound method; returns a disposer. */
  handle(method: InboundMethod, handler: InboundHandler): () => void
  /** Entry point for Native → Web messages (installed as `window.__DSH_STUDIO__.receive`). */
  receive(raw: unknown): void
  /** True once an unknown protocol version was seen: the bridge is inert from then on (§4). */
  readonly degraded: boolean
}

/** Bridge construction options. */
export interface BridgeOptions {
  transport: BridgeTransport
  ulid?: UlidFactory
  timers?: TimerSeam
  /**
   * Called once when a message carries an unknown `v`. The contract says:
   * do not guess, do not adapt — degrade to the official Web UI and report
   * (§1.2 / §4). Tearing the registrations down is the caller's job.
   */
  onProtocolMismatch?: (version: unknown) => void
  /** Diagnostics sink; payloads are never logged by default (§5, last row). */
  onDiagnostic?: (message: string) => void
}

interface PendingRequest {
  resolve(value: unknown): void
  reject(error: Error): void
  timer: unknown
  method: string
}

/** Structural decode result of one inbound envelope. */
type Decoded =
  | { kind: 'req'; id: string; method: string; payload: Record<string, unknown> }
  | { kind: 'res'; id: string; ok: true; payload: unknown }
  | { kind: 'res'; id: string; ok: false; error: WireError }
  | { kind: 'evt'; method: string; payload: Record<string, unknown> }
  | { kind: 'version'; version: unknown }
  | { kind: 'invalid'; reason: string; id?: string }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asWireError(value: unknown): WireError {
  if (!isRecord(value)) return { code: 'internal', message: 'malformed error object', retryable: false }
  const code = value.code
  const known = BRIDGE_ERROR_CODES.find(candidate => candidate === code)
  const message = typeof value.message === 'string' ? value.message : String(code ?? 'internal')
  // An unknown code is itself a protocol violation; it is reported as such
  // rather than passed through (the set is closed, §1.5).
  return { code: known ?? 'protocol_mismatch', message, retryable: false }
}

/**
 * Decode one inbound message into the envelope union (§1.2).
 * @param raw - a JSON string or an already-parsed value.
 * @returns the decoded envelope, or an `invalid` / `version` verdict.
 */
export function decodeEnvelope(raw: unknown): Decoded {
  let value: unknown = raw
  if (typeof raw === 'string') {
    try {
      value = JSON.parse(raw)
    } catch {
      return { kind: 'invalid', reason: 'not JSON' }
    }
  }
  if (!isRecord(value)) return { kind: 'invalid', reason: 'envelope is not an object' }
  if (value.v !== PROTOCOL_VERSION) return { kind: 'version', version: value.v }

  const id = typeof value.id === 'string' ? value.id : undefined
  switch (value.t) {
    case 'req': {
      if (id === undefined) return { kind: 'invalid', reason: 'req without id' }
      if (typeof value.m !== 'string') return { kind: 'invalid', reason: 'req without method', id }
      if (value.p !== undefined && !isRecord(value.p)) return { kind: 'invalid', reason: 'req payload is not an object', id }
      return { kind: 'req', id, method: value.m, payload: isRecord(value.p) ? value.p : {} }
    }
    case 'res': {
      if (id === undefined) return { kind: 'invalid', reason: 'res without id' }
      if (value.ok === true) return { kind: 'res', id, ok: true, payload: value.p }
      if (value.ok === false) return { kind: 'res', id, ok: false, error: asWireError(value.e) }
      return { kind: 'invalid', reason: 'res without ok', id }
    }
    case 'evt': {
      if (typeof value.m !== 'string') return { kind: 'invalid', reason: 'evt without method' }
      if (value.p !== undefined && !isRecord(value.p)) return { kind: 'invalid', reason: 'evt payload is not an object' }
      return { kind: 'evt', method: value.m, payload: isRecord(value.p) ? value.p : {} }
    }
    default:
      return { kind: 'invalid', reason: `unknown envelope type ${JSON.stringify(value.t)}`, ...(id === undefined ? {} : { id }) }
  }
}

/**
 * Create the control channel.
 * @param options - transport plus injectable seams.
 * @returns the bridge face.
 */
export function createBridge(options: BridgeOptions): Bridge {
  const { transport } = options
  const mintId = options.ulid ?? createUlid()
  const timers = options.timers ?? REAL_TIMERS
  const diagnose = options.onDiagnostic ?? ((): void => {})
  const handlers = new Map<InboundMethod, InboundHandler>()
  const pending = new Map<string, PendingRequest>()
  let degraded = false

  const send = (envelope: Record<string, unknown>, options: { evenWhenDegraded?: boolean } = {}): void => {
    if (degraded && options.evenWhenDegraded !== true) {
      diagnose(`suppressed ${String(envelope.m ?? envelope.t)} after protocol mismatch`)
      return
    }
    transport.post(JSON.stringify(envelope))
  }

  const respond = (id: string, result: { ok: true; payload: unknown } | { ok: false; error: WireError }): void => {
    if (result.ok) {
      send({ v: PROTOCOL_VERSION, t: 'res', id, ok: true, ...(result.payload === undefined ? {} : { p: result.payload }) })
      return
    }
    // A `protocol_mismatch` receipt is the one thing that still crosses a
    // degraded channel. The suppression exists to stop orchestration (§4), not
    // to hide the diagnosis, and staying silent would leave the host's request
    // hanging until its own timeout — a worse failure than one honest answer.
    send(
      { v: PROTOCOL_VERSION, t: 'res', id, ok: false, e: result.error },
      { evenWhenDegraded: result.error.code === 'protocol_mismatch' },
    )
  }

  const degrade = (version: unknown): void => {
    if (degraded) return
    degraded = true
    diagnose(`protocol mismatch: expected v${PROTOCOL_VERSION}, got ${JSON.stringify(version)}`)
    for (const [id, request] of pending) {
      timers.clearTimeout(request.timer)
      pending.delete(id)
      request.reject(bridgeError('protocol_mismatch', `bridge degraded while ${request.method} was in flight`))
    }
    options.onProtocolMismatch?.(version)
  }

  const dispatchRequest = (id: string, method: string, payload: Record<string, unknown>): void => {
    const known = INBOUND_METHODS.find(candidate => candidate === method)
    if (known === undefined) {
      respond(id, { ok: false, error: bridgeError('unknown_method', `no handler for "${method}"`).toWire() })
      return
    }
    const handler = handlers.get(known)
    if (handler === undefined) {
      respond(id, { ok: false, error: bridgeError('unknown_method', `method "${method}" has no installed handler`).toWire() })
      return
    }
    let result: unknown
    try {
      result = handler(payload)
    } catch (error) {
      respond(id, { ok: false, error: toWireError(error) })
      return
    }
    // A handler may answer synchronously or with a promise; both settle onto
    // exactly one `res` (the contract has no partial receipts).
    void Promise.resolve(result).then(
      value => { respond(id, { ok: true, payload: value }) },
      error => { respond(id, { ok: false, error: toWireError(error) }) },
    )
  }

  const bridge: Bridge = {
    get degraded() { return degraded },

    emit(method, payload) {
      send({ v: PROTOCOL_VERSION, t: 'evt', m: method, p: payload })
    },

    request(method, payload, requestOptions) {
      if (degraded) {
        return Promise.reject(bridgeError('protocol_mismatch', 'bridge is degraded; no further requests are sent'))
      }
      const id = mintId()
      const budget = requestOptions?.timeoutMs ?? timeoutFor(method)
      return new Promise<unknown>((resolve, reject) => {
        const timer = timers.setTimeout(() => {
          // Timeout is terminal: the closed error set has no retryable code,
          // and a retried orchestration request would double-mount (§1.5).
          pending.delete(id)
          reject(bridgeError('internal', `request "${method}" timed out after ${budget}ms (not retried)`))
        }, budget)
        pending.set(id, { resolve, reject, timer, method })
        send({ v: PROTOCOL_VERSION, t: 'req', id, m: method, p: payload })
      })
    },

    handle(method, handler) {
      if (handlers.has(method)) {
        throw bridgeError('internal', `handler for "${method}" is already installed`)
      }
      handlers.set(method, handler)
      return () => {
        if (handlers.get(method) === handler) handlers.delete(method)
      }
    },

    receive(raw) {
      const decoded = decodeEnvelope(raw)
      switch (decoded.kind) {
        case 'version':
          degrade(decoded.version)
          return
        case 'invalid': {
          diagnose(`dropped inbound message: ${decoded.reason}`)
          if (decoded.id !== undefined && !degraded) {
            respond(decoded.id, { ok: false, error: bridgeError('bad_payload', decoded.reason).toWire() })
          }
          return
        }
        case 'req': {
          if (degraded) {
            respond(decoded.id, { ok: false, error: bridgeError('protocol_mismatch', 'bridge is degraded').toWire() })
            return
          }
          dispatchRequest(decoded.id, decoded.method, decoded.payload)
          return
        }
        case 'res': {
          const request = pending.get(decoded.id)
          if (request === undefined) {
            // Late receipt of a timed-out request, or a duplicate. Dropping is
            // correct: orchestration is idempotent, not transactional (§1.4).
            diagnose(`dropped res for unknown id ${decoded.id}`)
            return
          }
          timers.clearTimeout(request.timer)
          pending.delete(decoded.id)
          if (decoded.ok) request.resolve(decoded.payload)
          else request.reject(new BridgeFailure(decoded.error.code, decoded.error.message))
          return
        }
        case 'evt':
          // The Web half answers no inbound events today: every §1.3 row in the
          // Native → Web direction is a `req`. Dropping keeps the method table
          // closed instead of silently growing one.
          diagnose(`dropped inbound evt "${decoded.method}" (no inbound events in the contract)`)
      }
    },
  }

  return bridge
}

/**
 * Map a thrown value onto the closed error set.
 * @param error - whatever a handler threw.
 * @returns the wire error.
 */
function toWireError(error: unknown): WireError {
  if (error instanceof BridgeFailure) return error.toWire()
  return { code: 'internal', message: error instanceof Error ? error.message : String(error), retryable: false }
}

/** Shape `window.webkit.messageHandlers.studio` (WKScriptMessageHandler, §1.1). */
export interface WebkitScope {
  webkit?: {
    messageHandlers?: {
      studio?: { postMessage(body: string): void }
    }
  }
}

/**
 * Build the WKWebView transport.
 * @param scope - the window-like object carrying `webkit.messageHandlers`.
 * @returns the transport, or undefined when the page is not hosted by Studio
 * (a plain browser: the client half then stays inert instead of throwing).
 */
export function webkitTransport(scope: WebkitScope): BridgeTransport | undefined {
  const handler = scope.webkit?.messageHandlers?.studio
  if (handler === undefined) return undefined
  return { post: (json) => { handler.postMessage(json) } }
}

/** The `window.__DSH_STUDIO__` global the host calls into (§1.1). */
export interface StudioGlobal {
  receive(raw: unknown): void
  protocol: number
}

/** Window-like target the receiver is mounted on. */
export interface ReceiverScope {
  __DSH_STUDIO__?: StudioGlobal | undefined
}

/**
 * Mount `window.__DSH_STUDIO__` reversibly. Call inside `ctx.effect` so plugin
 * unload takes the global back off (§1.1).
 * @param bridge - the bridge to expose.
 * @param scope - window-like target.
 * @returns disposer restoring the previous value.
 */
export function installReceiver(bridge: Bridge, scope: ReceiverScope): () => void {
  const previous = scope.__DSH_STUDIO__
  const installed: StudioGlobal = {
    protocol: PROTOCOL_VERSION,
    receive: (raw) => { bridge.receive(raw) },
  }
  scope.__DSH_STUDIO__ = installed
  return () => {
    if (scope.__DSH_STUDIO__ === installed) scope.__DSH_STUDIO__ = previous
  }
}
