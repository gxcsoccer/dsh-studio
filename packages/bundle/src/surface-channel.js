/**
 * The private chrome channel between the Swift host and this client plugin.
 *
 * This is not a Harness seam. It does not go on the carrier, it does not add
 * methods to `RpcMethodMap`, and a regular browser tab opening the loopback
 * URL will simply not have `webkit.messageHandlers.studio`. The channel exists
 * because chrome state (which workspace the menu just opened, which session
 * the native sidebar will highlight) lives on the other side of a WKWebView.
 *
 * Envelope (keep in lockstep with `app/Sources/DSHSurface/SurfaceEnvelope.swift`):
 *
 *   { v: 1, type: 'req', id, method, payload }
 *   { v: 1, type: 'res', id, ok: true,  value }
 *   { v: 1, type: 'res', id, ok: false, error }
 *   { v: 1, type: 'evt', method, payload }
 */

export const VERSION = 1
export const HANDLER = 'studio'

export function encodeRequest(id, method, payload) {
  return { v: VERSION, type: 'req', id, method, payload: payload ?? {} }
}

export function encodeResponse(id, value) {
  return { v: VERSION, type: 'res', id, ok: true, value: value ?? {} }
}

export function encodeError(id, error) {
  const message = error instanceof Error ? error.message : String(error)
  return { v: VERSION, type: 'res', id, ok: false, error: message }
}

export function encodeEvent(method, payload) {
  return { v: VERSION, type: 'evt', method, payload: payload ?? {} }
}

/** @returns the frame, or `null` when it is not ours to handle. */
export function parseFrame(input) {
  const frame = typeof input === 'string' ? JSON.parse(input) : input
  if (!frame || typeof frame !== 'object') return null
  if (frame.v !== VERSION) return null
  if (frame.type !== 'req' && frame.type !== 'res' && frame.type !== 'evt') return null
  return frame
}

export function nativeHandler(global = globalThis) {
  return global.webkit?.messageHandlers?.[HANDLER] ?? null
}

/**
 * Install the page-side hook the native host calls via `evaluateJavaScript`.
 * Returns `null` when there is no native host — the same plugin then just
 * does not offer chrome-driven navigation, which is how browser dogfood works.
 *
 * @param {{ onRequest: (frame: object) => Promise<unknown> }} opts
 */
export function attachSurface(opts, global = globalThis) {
  const handler = nativeHandler(global)
  if (!handler) return null

  const post = (frame) => handler.postMessage(frame)

  const api = {
    dispatch(input) {
      const frame = parseFrame(input)
      if (!frame || frame.type !== 'req') return Promise.resolve()
      return Promise.resolve()
        .then(() => opts.onRequest(frame))
        .then((value) => post(encodeResponse(frame.id, value ?? {})))
        .catch((error) => post(encodeError(frame.id, error?.message ?? error)))
    },
    event(method, payload) {
      post(encodeEvent(method, payload))
    },
  }

  global.__DSH_STUDIO__ = api
  post(encodeEvent('ready', {}))
  return api
}
