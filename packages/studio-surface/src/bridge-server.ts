/**
 * Data channel — the host half of bridge-contract.md §2.
 *
 * One `node:http` server on `127.0.0.1`, three responsibilities:
 *
 *   1. **RPC forwarding** (§2.2a). `POST /rpc { method, params }` is repacked
 *      into the official `client-request` envelope and handed to
 *      `toFetchHandler(ctx.apiProxy)`. The value domain of `method` is
 *      upstream's `RpcMethodMap` and nothing else: an unknown method comes back
 *      404 *from upstream*, because a shadow API would break the day upstream
 *      renames a route.
 *   2. **Event fan-out** (§2.2b, §2.3). The official mux and host SSE streams
 *      are consumed once, retained in a bounded ring, and fanned out to native
 *      clients with `id:` lines so a reconnect can resume via `Last-Event-ID`.
 *      Past the retention window the host is told to re-baseline instead of
 *      being handed a silent gap.
 *   3. **The `/studio/*` prefix** — Studio's own few needs, kept strictly
 *      apart from the forwarding face (§2.2a, last paragraph).
 *
 * Security posture (§5): loopback is asserted in code, every request carries a
 * one-time Bearer token, and a browser-originated request is refused outright.
 * "Loopback" is not a synonym for "trusted": another process on the same
 * machine must not be able to drive the user's agent.
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { randomUUID, randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import type { Manifest } from '@dsh-studio/studio-client/src/index.ts'
import { LOOPBACK_ADDRESS, type SlotMode } from './config.ts'

/** Fetch-shaped seam over the official gateway (`toFetchHandler(ctx.apiProxy)`). */
export interface UpstreamFetch {
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>
}

/** What `GET /studio/surface` answers: the control plane, read by the native host. */
export interface SurfaceInfo {
  /** Control-channel protocol version the client half speaks. */
  protocol: number
  /** The configured manifest, in wire form. */
  manifest: Manifest
  /** Hotkey that flips the focused slot back to the official UI. */
  compareHotkey: string
  /** Migration census, derived from the manifest. */
  census: Record<SlotMode, number>
}

/** Server construction options. */
export interface BridgeServerOptions {
  port: number
  /** One-time Bearer token; see {@link mintToken}. */
  token: string
  upstream: UpstreamFetch
  /** Read lazily, so a config hot-patch is visible without a restart. */
  surface: () => SurfaceInfo
  /** Retained events per stream (§2.3 retention window). */
  retention?: number
  /** Delay before re-opening an upstream stream that ended. */
  reopenDelayMs?: number
  /** Diagnostics sink; payloads are never logged (§5, last row). */
  log?: (message: string) => void
}

/** The running server. */
export interface BridgeServer {
  readonly port: number
  /** `http://127.0.0.1:<port>` — what the handshake file publishes. */
  readonly origin: string
  /** Currently attached SSE clients (diagnostics + test assertions). */
  readonly clients: number
  /** Ids already handed out, i.e. the resume cursor high-water mark. */
  readonly cursor: number
  close(): Promise<void>
}

/**
 * Method-name shape. It does **not** enumerate methods (that is upstream's
 * job): it only guarantees the name cannot escape the `/api/` prefix, so a
 * crafted `method` can never reach another route by path traversal.
 */
export const RPC_METHOD_PATTERN = /^[a-z][A-Za-z0-9]*\.[a-zA-Z][A-Za-z0-9]*$/

/** Bytes of entropy in the data-channel token. */
const TOKEN_BYTES = 32

/**
 * Mint a one-time data-channel token (§2.1).
 * @returns a 256-bit hex token.
 */
export function mintToken(): string {
  return randomBytes(TOKEN_BYTES).toString('hex')
}

/**
 * Assert the bind address. The bind address is not a configuration option and
 * this assertion is the reason (§5, row 1): `0.0.0.0` would expose the user's
 * agent to their whole network, and no feature is worth that risk.
 * @param address - candidate bind address.
 * @throws Error when the address is anything but `127.0.0.1`.
 */
export function assertLoopback(address: string): void {
  if (address !== LOOPBACK_ADDRESS) {
    throw new Error(`refusing to bind "${address}": the Studio data channel binds ${LOOPBACK_ADDRESS} only`)
  }
}

/**
 * Contents of `$DSH_HOME/studio/bridge.json` (§2.1).
 *
 * The field table is part of the contract, not an implementation detail: the
 * native half decodes exactly these keys (`apps/macos` `BridgeDescriptor`), and
 * it treats a missing `host` as the loopback literal and a missing `webUrl` as
 * "no official shell address published yet". Both are therefore written
 * explicitly whenever they are known — a native half that has to guess where
 * the Web shell lives shows the user a "runtime offline" screen instead.
 */
export interface Handshake {
  /** Bind host. Always the loopback literal; it is asserted, never configured (§5). */
  host: string
  port: number
  /** `http://<host>:<port>` — the same value, pre-joined for HTTP clients. */
  origin: string
  token: string
  protocol: number
  pid: number
  /**
   * URL of the official Web shell the native half loads into its WebView.
   * Omitted when the deployment did not configure one, in which case the native
   * half falls back to its own `DSH_STUDIO_SHELL_URL` escape hatch.
   */
  webUrl?: string
}

/**
 * Publish the handshake file with `0600` permissions (§2.1).
 *
 * `chmod` is applied after the write because `writeFileSync`'s mode is masked
 * by the process umask — passing `0o600` alone can still leave a group- or
 * world-readable token on a permissive umask.
 * @param path - absolute file path.
 * @param handshake - contents.
 * @returns a disposer that removes the file again.
 */
export function writeHandshakeFile(path: string, handshake: Handshake): () => void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  writeFileSync(path, `${JSON.stringify(handshake, null, 2)}\n`, { mode: 0o600 })
  chmodSync(path, 0o600)
  return () => { rmSync(path, { force: true }) }
}

/** One retained SSE frame. */
interface Retained {
  id: number
  event: string
  data: string
}

/** Bounded retention ring: the executable form of "surface 侧保留窗口" (§2.3). */
class Ring {
  private readonly items: Retained[] = []

  constructor(private readonly capacity: number) {}

  /**
   * @param frame - frame to retain.
   */
  push(frame: Retained): void {
    this.items.push(frame)
    while (this.items.length > this.capacity) this.items.shift()
  }

  /** Oldest retained id, or undefined when nothing is retained. */
  get oldest(): number | undefined {
    return this.items[0]?.id
  }

  /**
   * Frames a resuming client missed.
   * @param lastId - the client's `Last-Event-ID`.
   * @returns `{ ok: true, frames }` when the window still covers the gap,
   * `{ ok: false }` when the client must re-baseline through `session.history`.
   */
  since(lastId: number): { ok: true; frames: Retained[] } | { ok: false } {
    const oldest = this.oldest
    // Nothing retained yet: the client is trivially up to date.
    if (oldest === undefined) return { ok: true, frames: [] }
    // The gap starts before the window: refusing is the honest answer (§2.3).
    if (lastId + 1 < oldest) return { ok: false }
    return { ok: true, frames: this.items.filter(item => item.id > lastId) }
  }
}

/** An attached SSE client. */
interface Client {
  response: ServerResponse
  /** Which stream families this client listens to (all of them today). */
  write(frame: Retained): void
}

/** Upstream stream definition: one official SSE endpoint plus its event naming. */
interface StreamSource {
  /** Upstream path handed to the official fetch handler. */
  path: string
  /**
   * SSE `event:` name for a frame of this stream. `session/event` frames get
   * the documented `session` name; everything else keeps its family so a
   * native client can ignore what it does not model yet.
   */
  name(payload: Record<string, unknown>): string
  /**
   * Wire body. For a session event the documented shape is
   * `{ sessionId, seq, event }` (§2.2b); for anything else the upstream frame
   * rides verbatim, because reshaping it would make Studio a second
   * authority over domain data (ADR-0002).
   */
  body(payload: Record<string, unknown>): unknown
}

/** Extract a session event's `seq`, the per-session watermark (`SessionEvent.seq`). */
function seqOf(payload: Record<string, unknown>): number | undefined {
  const event = payload.event
  if (typeof event !== 'object' || event === null) return undefined
  const seq = (event as { seq?: unknown }).seq
  return typeof seq === 'number' ? seq : undefined
}

const MUX_STREAM: StreamSource = {
  path: '/api/events.mux',
  name: payload => (payload.type === 'session/event' ? 'session' : 'mux'),
  body: (payload) => {
    if (payload.type !== 'session/event') return payload
    const seq = seqOf(payload)
    return {
      sessionId: payload.sessionId,
      ...(seq === undefined ? {} : { seq }),
      event: payload.event,
      ...(payload.view === undefined ? {} : { view: payload.view }),
    }
  },
}

const HOST_STREAM: StreamSource = {
  path: '/api/events.host',
  name: () => 'host',
  body: payload => payload,
}

/** Split an SSE text buffer into complete frames; returns the unconsumed tail. */
function drainSse(buffer: string): { payloads: string[]; rest: string } {
  const payloads: string[] = []
  let rest = buffer
  while (true) {
    const boundary = rest.indexOf('\n\n')
    if (boundary === -1) return { payloads, rest }
    const block = rest.slice(0, boundary)
    rest = rest.slice(boundary + 2)
    const data = block.split('\n')
      .filter(line => line.startsWith('data:'))
      .map(line => line.slice('data:'.length).trimStart())
      .join('\n')
    // A comment-only block (`: connected`) yields no data lines: skip it.
    if (data.length > 0) payloads.push(data)
  }
}

/**
 * Start the data channel.
 *
 * The upstream streams are opened once at startup, not per client: the
 * retention window has to survive a native reconnect, which is the entire
 * point of `Last-Event-ID` resume.
 * @param options - server options.
 * @returns the running server.
 * @throws Error when the port is taken — deliberately, instead of picking
 * another port (§2.1: a moved port is a port the host cannot find).
 */
export async function startBridgeServer(options: BridgeServerOptions): Promise<BridgeServer> {
  const log = options.log ?? ((): void => {})
  const retention = options.retention ?? 1024
  const reopenDelayMs = options.reopenDelayMs ?? 1_000
  const ring = new Ring(retention)
  const clients = new Set<Client>()
  const timers = new Set<NodeJS.Timeout>()
  let cursor = 0
  let closing = false

  const publish = (event: string, body: unknown): void => {
    cursor += 1
    const frame: Retained = { id: cursor, event, data: JSON.stringify(body) }
    ring.push(frame)
    for (const client of clients) client.write(frame)
  }

  // ── upstream stream pumps ───────────────────────────────────────────────
  const pump = async (source: StreamSource): Promise<void> => {
    while (!closing) {
      try {
        const response = await options.upstream.fetch(
          new Request(`http://${LOOPBACK_ADDRESS}${source.path}`, { method: 'GET' }),
        )
        const body = response.body
        if (body === null) throw new Error(`upstream ${source.path} returned no body`)
        const reader = body.getReader()
        const decoder = new TextDecoder()
        let buffer = ''
        while (!closing) {
          const chunk = await reader.read()
          if (chunk.done) break
          buffer += decoder.decode(chunk.value, { stream: true })
          const drained = drainSse(buffer)
          buffer = drained.rest
          for (const raw of drained.payloads) {
            let envelope: unknown
            try {
              envelope = JSON.parse(raw)
            } catch {
              log(`dropped an unparsable frame from ${source.path}`)
              continue
            }
            const payload = (envelope as { payload?: unknown }).payload
            if (typeof payload !== 'object' || payload === null) continue
            const record = payload as Record<string, unknown>
            publish(source.name(record), source.body(record))
          }
        }
        await reader.cancel().catch(() => { /* already closed */ })
      } catch (error) {
        if (closing) return
        log(`upstream ${source.path} failed: ${error instanceof Error ? error.message : String(error)}`)
      }
      if (closing) return
      // The official mux stream lives as long as the process, so an end is
      // abnormal. The host is told, then we retry: a silent stop would look
      // exactly like an idle agent (§2.3 — the disconnect banner is the first
      // thing worth making native).
      publish('studio/upstream-closed', { path: source.path, retryInMs: reopenDelayMs })
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => { timers.delete(timer); resolve() }, reopenDelayMs)
        timers.add(timer)
      })
    }
  }

  // ── request handling ────────────────────────────────────────────────────
  const expected = Buffer.from(options.token)

  const authorized = (request: IncomingMessage): boolean => {
    const header = request.headers.authorization
    if (header === undefined || !header.startsWith('Bearer ')) return false
    const presented = Buffer.from(header.slice('Bearer '.length))
    // Length must match before timingSafeEqual, which throws otherwise; the
    // length itself is not a secret.
    if (presented.length !== expected.length) return false
    return timingSafeEqual(presented, expected)
  }

  const json = (response: ServerResponse, status: number, body: unknown): void => {
    const payload = JSON.stringify(body)
    response.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(payload),
      // The data channel is never a web origin's resource.
      'cache-control': 'no-store',
    })
    response.end(payload)
  }

  const readBody = async (request: IncomingMessage): Promise<string> => {
    const chunks: Buffer[] = []
    for await (const chunk of request) chunks.push(chunk as Buffer)
    return Buffer.concat(chunks).toString('utf8')
  }

  const handleRpc = async (request: IncomingMessage, response: ServerResponse): Promise<void> => {
    const mediaType = request.headers['content-type']?.split(';', 1)[0]?.trim().toLowerCase()
    if (mediaType !== 'application/json') {
      json(response, 415, { error: { code: 'unsupported-media-type', message: 'content type must be application/json' } })
      return
    }
    let body: unknown
    try {
      body = JSON.parse(await readBody(request))
    } catch {
      json(response, 400, { error: { code: 'bad-request', message: 'body is not JSON' } })
      return
    }
    const method = (body as { method?: unknown } | null)?.method
    if (typeof method !== 'string' || !RPC_METHOD_PATTERN.test(method)) {
      json(response, 400, { error: { code: 'bad-request', message: 'method must be a "<domain>.<action>" name' } })
      return
    }
    const params = (body as { params?: unknown }).params ?? {}
    const controller = new AbortController()
    response.on('close', () => { controller.abort() })
    // The official envelope, verbatim. `rpcId` correlates the call in the
    // host's own logs; the native side never needs to mint one.
    const envelope = { type: 'client-request', rpcId: randomUUID(), method, payload: params }
    const upstream = await options.upstream.fetch(
      new Request(`http://${LOOPBACK_ADDRESS}/api/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(envelope),
        signal: controller.signal,
      }),
    )
    const text = await upstream.text()
    // Relayed verbatim, status included: a 404 means "not in upstream's
    // RpcMethodMap", and translating it into a Studio-flavoured error would be
    // the first brick of the shadow API §2.2a forbids.
    response.writeHead(upstream.status, {
      'content-type': upstream.headers.get('content-type') ?? 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(text),
      'cache-control': 'no-store',
    })
    response.end(text)
  }

  const handleEvents = (request: IncomingMessage, response: ServerResponse, url: URL): void => {
    const headerId = request.headers['last-event-id']
    const rawId = (Array.isArray(headerId) ? headerId[0] : headerId) ?? url.searchParams.get('lastEventId') ?? undefined
    const lastId = rawId === undefined ? undefined : Number.parseInt(rawId, 10)

    response.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      connection: 'keep-alive',
    })
    const write = (frame: Retained): void => {
      response.write(`id: ${frame.id}\nevent: ${frame.event}\ndata: ${frame.data}\n\n`)
    }
    // Same comment line the official handler opens with: proves a live channel
    // while both streams are idle.
    response.write(': connected\n\n')

    if (lastId !== undefined && Number.isFinite(lastId)) {
      const resumed = ring.since(lastId)
      if (resumed.ok) {
        for (const frame of resumed.frames) write(frame)
      } else {
        // §2.3: the host drops the increment and refetches a full snapshot.
        response.write(`event: studio/replay-gap\ndata: ${JSON.stringify({
          requested: lastId,
          oldest: ring.oldest ?? null,
          retention,
          advice: 'session.history',
        })}\n\n`)
      }
    }

    const client: Client = { response, write }
    clients.add(client)
    log(`SSE client attached (${clients.size} total)`)
    const detach = (): void => {
      clients.delete(client)
      log(`SSE client detached (${clients.size} total)`)
    }
    response.on('close', detach)
  }

  const server: Server = createServer((request, response) => {
    void (async () => {
      try {
        // Defence in depth: the socket is bound to loopback already, but a
        // misconfigured proxy in front of it would be invisible otherwise.
        const remote = request.socket.remoteAddress ?? ''
        if (remote !== LOOPBACK_ADDRESS && remote !== '::1' && remote !== '::ffff:127.0.0.1') {
          json(response, 403, { error: { code: 'forbidden', message: 'the data channel serves loopback only' } })
          return
        }
        // A browser always attaches `Origin` to a cross-origin request. The
        // data channel has no web client, so its presence means a page is
        // probing us — refuse before touching the token.
        if (request.headers.origin !== undefined) {
          json(response, 403, { error: { code: 'forbidden', message: 'the data channel is not a web origin resource' } })
          return
        }
        if (!authorized(request)) {
          json(response, 401, { error: { code: 'unauthorized', message: 'missing or invalid bearer token' } })
          return
        }

        const url = new URL(request.url ?? '/', `http://${LOOPBACK_ADDRESS}`)
        const path = url.pathname
        if (path === '/rpc' && request.method === 'POST') {
          await handleRpc(request, response)
          return
        }
        if (path === '/events' && request.method === 'GET') {
          handleEvents(request, response, url)
          return
        }
        if (path === '/studio/surface' && request.method === 'GET') {
          json(response, 200, options.surface())
          return
        }
        if (path === '/studio/health' && request.method === 'GET') {
          json(response, 200, { ok: true, clients: clients.size, cursor, retention })
          return
        }
        json(response, 404, { error: { code: 'not-found', message: `no route for ${request.method ?? '?'} ${path}` } })
      } catch (error) {
        log(`request failed: ${error instanceof Error ? error.message : String(error)}`)
        if (!response.headersSent) {
          json(response, 500, { error: { code: 'internal', message: 'request failed' } })
        } else {
          response.end()
        }
      }
    })()
  })

  assertLoopback(LOOPBACK_ADDRESS)
  await new Promise<void>((resolve, reject) => {
    const onError = (error: NodeJS.ErrnoException): void => {
      server.removeListener('listening', onListening)
      if (error.code === 'EADDRINUSE') {
        reject(new Error(
          `port ${options.port} is already in use; the Studio data channel does not relocate `
          + '(a moved port is a port the native host cannot find). Free it or change bridge.port.',
        ))
        return
      }
      reject(error)
    }
    const onListening = (): void => {
      server.removeListener('error', onError)
      resolve()
    }
    server.once('error', onError)
    server.once('listening', onListening)
    server.listen({ host: LOOPBACK_ADDRESS, port: options.port })
  })

  const address = server.address()
  const port = typeof address === 'object' && address !== null ? address.port : options.port
  void pump(MUX_STREAM)
  void pump(HOST_STREAM)
  log(`data channel listening on http://${LOOPBACK_ADDRESS}:${port}`)

  return {
    port,
    origin: `http://${LOOPBACK_ADDRESS}:${port}`,
    get clients() { return clients.size },
    get cursor() { return cursor },
    async close() {
      closing = true
      for (const timer of timers) clearTimeout(timer)
      timers.clear()
      for (const client of clients) client.response.end()
      clients.clear()
      await new Promise<void>((resolve, reject) => {
        server.close(error => (error === undefined ? resolve() : reject(error)))
        // Idle keep-alive sockets would otherwise hold the port past unload,
        // and §2.1 requires it back clean on plugin dispose.
        server.closeAllConnections()
      })
      log('data channel closed')
    },
  }
}
