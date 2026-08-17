/**
 * Test doubles for the host half.
 *
 * The interesting one is {@link fakeUpstream}: it imitates
 * `toFetchHandler(ctx.apiProxy)` closely enough to be worth trusting —
 * `POST /api/<method>` takes the `client-request` envelope, and the two SSE
 * endpoints emit the exact frame shape upstream's `sseResponse` writes
 * (`: connected` comment first, then
 * `data: {"type":"server-request","rpcId":…,"method":…,"payload":…}`), because
 * the forwarding code is only correct relative to that shape.
 */

import { createServer as createRawServer } from 'node:net'
import { request as httpRequest, type IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
import type { UpstreamFetch } from '../src/bridge-server.ts'
import { LOOPBACK_ADDRESS } from '../src/config.ts'

/** One forwarded RPC as the fake gateway saw it. */
export interface UpstreamCall {
  path: string
  method: string
  /** The parsed request body — the official `client-request` envelope. */
  body: Record<string, unknown>
}

/** How the fake gateway answers `POST /api/<method>`. */
export interface UpstreamReply {
  status?: number
  body?: unknown
  contentType?: string
  /** Raw text body, when the point is that it is relayed verbatim. */
  text?: string
}

/** The fake official gateway. */
export interface FakeUpstream extends UpstreamFetch {
  readonly calls: readonly UpstreamCall[]
  /** Install the reply for the next RPCs. */
  reply(handler: (call: UpstreamCall) => UpstreamReply): void
  /** Emit one frame on an upstream SSE endpoint. */
  push(path: string, payload: Record<string, unknown>): void
  /** End an upstream SSE stream, as an abnormal close. */
  endStream(path: string): void
  /** Resolves once the server has opened the given stream. */
  opened(path: string): Promise<void>
  /** How many times a stream was opened (reopen assertions). */
  opens(path: string): number
}

/**
 * Build the fake gateway.
 * @returns the double.
 */
export function fakeUpstream(): FakeUpstream {
  const encoder = new TextEncoder()
  const calls: UpstreamCall[] = []
  const controllers = new Map<string, ReadableStreamDefaultController<Uint8Array>>()
  const waiters = new Map<string, Array<() => void>>()
  const openCounts = new Map<string, number>()
  let handler: (call: UpstreamCall) => UpstreamReply = () => ({ status: 200, body: { ok: true } })

  const announce = (path: string): void => {
    openCounts.set(path, (openCounts.get(path) ?? 0) + 1)
    for (const resolve of waiters.get(path) ?? []) resolve()
    waiters.delete(path)
  }

  return {
    calls,

    reply(next) { handler = next },

    push(path, payload) {
      const controller = controllers.get(path)
      if (controller === undefined) throw new Error(`stream ${path} is not open`)
      const frame = { type: 'server-request', rpcId: 'rpc-test', method: payload.type ?? 'unknown', payload }
      controller.enqueue(encoder.encode(`data: ${JSON.stringify(frame)}\n\n`))
    },

    endStream(path) {
      const controller = controllers.get(path)
      if (controller === undefined) return
      controllers.delete(path)
      controller.close()
    },

    opened(path) {
      if (controllers.has(path)) return Promise.resolve()
      return new Promise<void>((resolve) => {
        const queue = waiters.get(path) ?? []
        queue.push(resolve)
        waiters.set(path, queue)
      })
    },

    opens(path) { return openCounts.get(path) ?? 0 },

    async fetch(input) {
      const requested = input instanceof Request ? input : new Request(input)
      const path = new URL(requested.url).pathname
      if (path === '/api/events.mux' || path === '/api/events.host') {
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            controllers.set(path, controller)
            controller.enqueue(encoder.encode(': connected\n\n'))
            announce(path)
          },
          cancel() { controllers.delete(path) },
        })
        return new Response(stream, { headers: { 'content-type': 'text/event-stream' } })
      }
      const body = JSON.parse(await requested.text()) as Record<string, unknown>
      const call: UpstreamCall = { path, method: requested.method, body }
      calls.push(call)
      const reply = handler(call)
      const text = reply.text ?? JSON.stringify(reply.body ?? { ok: true })
      return new Response(text, {
        status: reply.status ?? 200,
        headers: { 'content-type': reply.contentType ?? 'application/json; charset=utf-8' },
      })
    },
  }
}

/**
 * Take a port, then give it back: the number is then free to bind.
 * @returns a port number nothing is listening on.
 */
export async function freePort(): Promise<number> {
  const server = createRawServer()
  await new Promise<void>((resolve) => { server.listen(0, LOOPBACK_ADDRESS, resolve) })
  const port = (server.address() as AddressInfo).port
  await new Promise<void>((resolve) => { server.close(() => { resolve() }) })
  return port
}

/** One HTTP exchange with the data channel. */
export interface HttpResult {
  status: number
  headers: Record<string, string | string[] | undefined>
  text: string
  /** Parsed body; undefined when the body is not JSON. */
  json(): unknown
}

/** Request options; every header is explicit so nothing sneaks in. */
export interface HttpOptions {
  method?: string
  path?: string
  token?: string
  headers?: Record<string, string>
  body?: string
}

/**
 * Talk to the data channel over raw `node:http` (no `fetch`, whose implicit
 * headers would blur what the server is actually being told).
 * @param origin - `http://127.0.0.1:<port>`.
 * @param options - request options.
 * @returns the response.
 */
export async function http(origin: string, options: HttpOptions = {}): Promise<HttpResult> {
  const url = new URL(options.path ?? '/', origin)
  return new Promise<HttpResult>((resolve, reject) => {
    const request = httpRequest({
      hostname: url.hostname,
      port: url.port,
      path: `${url.pathname}${url.search}`,
      method: options.method ?? 'GET',
      headers: {
        ...(options.token === undefined ? {} : { authorization: `Bearer ${options.token}` }),
        ...(options.body === undefined ? {} : { 'content-length': Buffer.byteLength(options.body) }),
        ...options.headers,
      },
    }, (response: IncomingMessage) => {
      const chunks: Buffer[] = []
      response.on('data', chunk => chunks.push(chunk as Buffer))
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8')
        resolve({
          status: response.statusCode ?? 0,
          headers: response.headers,
          text,
          json() { return JSON.parse(text) as unknown },
        })
      })
    })
    request.on('error', reject)
    if (options.body !== undefined) request.write(options.body)
    request.end()
  })
}

/** One parsed SSE frame. */
export interface SseFrame {
  id?: number
  event?: string
  data?: unknown
  comment?: string
}

/** An attached SSE reader. */
export interface SseClient {
  readonly frames: readonly SseFrame[]
  /** Frames carrying an `event:` name (i.e. not the opening comment). */
  readonly events: readonly SseFrame[]
  /** Wait until at least `count` named events arrived. */
  waitFor(count: number, timeoutMs?: number): Promise<readonly SseFrame[]>
  close(): void
}

/**
 * Open an SSE connection and parse frames as they arrive.
 * @param origin - data-channel origin.
 * @param options - request options; `headers` carries `last-event-id`.
 * @returns the reader.
 */
export function openSse(origin: string, options: HttpOptions = {}): SseClient {
  const url = new URL(options.path ?? '/events', origin)
  const frames: SseFrame[] = []
  let buffer = ''
  const request = httpRequest({
    hostname: url.hostname,
    port: url.port,
    path: `${url.pathname}${url.search}`,
    method: 'GET',
    headers: {
      accept: 'text/event-stream',
      ...(options.token === undefined ? {} : { authorization: `Bearer ${options.token}` }),
      ...options.headers,
    },
  }, (response) => {
    response.setEncoding('utf8')
    response.on('data', (chunk: string) => {
      buffer += chunk
      while (true) {
        const boundary = buffer.indexOf('\n\n')
        if (boundary === -1) break
        const block = buffer.slice(0, boundary)
        buffer = buffer.slice(boundary + 2)
        const frame: SseFrame = {}
        for (const line of block.split('\n')) {
          if (line.startsWith(':')) frame.comment = line.slice(1).trim()
          else if (line.startsWith('id:')) frame.id = Number.parseInt(line.slice(3).trim(), 10)
          else if (line.startsWith('event:')) frame.event = line.slice(6).trim()
          else if (line.startsWith('data:')) frame.data = JSON.parse(line.slice(5).trim())
        }
        frames.push(frame)
      }
    })
  })
  request.end()

  const client: SseClient = {
    frames,
    get events() { return frames.filter(frame => frame.event !== undefined) },
    async waitFor(count, timeoutMs = 2_000) {
      const deadline = Date.now() + timeoutMs
      while (client.events.length < count) {
        if (Date.now() > deadline) {
          throw new Error(`timed out waiting for ${count} SSE events (saw ${client.events.length})`)
        }
        await new Promise<void>((resolve) => { setTimeout(resolve, 5) })
      }
      return client.events
    },
    close() { request.destroy() },
  }
  return client
}

/**
 * Poll until a condition holds.
 * @param predicate - condition.
 * @param what - description used in the timeout message.
 * @param timeoutMs - budget.
 */
export async function until(predicate: () => boolean, what: string, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await new Promise<void>((resolve) => { setTimeout(resolve, 5) })
  }
}
