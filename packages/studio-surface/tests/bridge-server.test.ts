/**
 * Data-channel tests — bridge-contract.md §2 (RPC forwarding, event fan-out,
 * resume), §2.1 (loopback, token, fixed port, handshake file) and §5 (the
 * security posture: loopback is not a synonym for trusted).
 */

import assert from 'node:assert/strict'
import { after, before, describe, test } from 'node:test'
import { createServer } from 'node:http'
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  RPC_METHOD_PATTERN, assertLoopback, mintToken, startBridgeServer, writeHandshakeFile,
  type BridgeServer, type SurfaceInfo,
} from '../src/bridge-server.ts'
import { LOOPBACK_ADDRESS } from '../src/config.ts'
import { fakeUpstream, freePort, http, openSse, until, type FakeUpstream } from './helpers.ts'

const MUX = '/api/events.mux'
const HOST = '/api/events.host'

const SURFACE: SurfaceInfo = {
  protocol: 1,
  manifest: { 'sidebar.workspaces': { mode: 'native', placement: 'evacuated', priority: -1 } },
  compareHotkey: 'opt+shift+d',
  census: { web: 0, mirrored: 0, native: 1, retired: 0 },
}

/** One running channel plus the pieces a test pokes at. */
interface Rig {
  server: BridgeServer
  upstream: FakeUpstream
  token: string
  origin: string
}

/**
 * Start a channel on a free port.
 * @param options - retention / reopen overrides.
 * @returns the rig.
 */
async function rig(options: { retention?: number; reopenDelayMs?: number } = {}): Promise<Rig> {
  const upstream = fakeUpstream()
  const token = mintToken()
  const server = await startBridgeServer({
    port: await freePort(),
    token,
    upstream,
    surface: () => SURFACE,
    ...(options.retention === undefined ? {} : { retention: options.retention }),
    ...(options.reopenDelayMs === undefined ? {} : { reopenDelayMs: options.reopenDelayMs }),
  })
  return { server, upstream, token, origin: server.origin }
}

/** Rigs to tear down after the file. */
const running: Rig[] = []

/**
 * Start a channel and register it for teardown.
 * @param options - see {@link rig}.
 * @returns the rig.
 */
async function managed(options: { retention?: number; reopenDelayMs?: number } = {}): Promise<Rig> {
  const instance = await rig(options)
  running.push(instance)
  return instance
}

after(async () => {
  for (const instance of running.splice(0)) await instance.server.close()
})

describe('binding (§2.1, §5)', () => {
  test('the origin is loopback and the port is the one that was asked for', async () => {
    const port = await freePort()
    const upstream = fakeUpstream()
    const server = await startBridgeServer({ port, token: mintToken(), upstream, surface: () => SURFACE })
    try {
      assert.equal(server.port, port)
      assert.equal(server.origin, `http://${LOOPBACK_ADDRESS}:${port}`)
    } finally {
      await server.close()
    }
  })

  test('any address other than 127.0.0.1 is refused in code, not in config', () => {
    assert.throws(() => assertLoopback('0.0.0.0'), /binds 127\.0\.0\.1 only/)
    assert.throws(() => assertLoopback('::1'), /binds 127\.0\.0\.1 only/)
    assert.throws(() => assertLoopback('localhost'), /binds 127\.0\.0\.1 only/)
  })

  test('an occupied port fails loud instead of relocating', async () => {
    const port = await freePort()
    const squatter = createServer(() => {})
    await new Promise<void>((resolve) => { squatter.listen(port, LOOPBACK_ADDRESS, resolve) })
    try {
      await assert.rejects(
        startBridgeServer({ port, token: mintToken(), upstream: fakeUpstream(), surface: () => SURFACE }),
        /already in use; the Studio data channel does not relocate/,
      )
    } finally {
      await new Promise<void>((resolve) => { squatter.close(() => { resolve() }) })
    }
  })

  test('close gives the port back, so a plugin reload can rebind it', async () => {
    const port = await freePort()
    const first = await startBridgeServer({ port, token: mintToken(), upstream: fakeUpstream(), surface: () => SURFACE })
    await first.close()
    const second = await startBridgeServer({ port, token: mintToken(), upstream: fakeUpstream(), surface: () => SURFACE })
    assert.equal(second.port, port)
    await second.close()
  })
})

describe('the token (§2.1, §5)', () => {
  test('a token is 256 bits of hex and never repeats', () => {
    const token = mintToken()
    assert.match(token, /^[0-9a-f]{64}$/)
    assert.notEqual(token, mintToken())
  })

  test('no token, a wrong token, and a wrong scheme are all 401', async () => {
    const instance = await managed()
    for (const options of [
      {},
      { token: 'deadbeef' },
      { token: 'f'.repeat(64) },
      { headers: { authorization: `Basic ${instance.token}` } },
    ]) {
      const response = await http(instance.origin, { path: '/studio/health', ...options })
      assert.equal(response.status, 401, JSON.stringify(options))
    }
  })

  test('the right token gets through', async () => {
    const instance = await managed()
    const response = await http(instance.origin, { path: '/studio/health', token: instance.token })
    assert.equal(response.status, 200)
    assert.deepEqual(response.json(), { ok: true, clients: 0, cursor: 0, retention: 1024 })
  })

  test('a request carrying an Origin header is refused before the token is read', async () => {
    const instance = await managed()
    const response = await http(instance.origin, {
      path: '/studio/health',
      token: instance.token,
      headers: { origin: 'http://evil.example' },
    })
    assert.equal(response.status, 403)
    assert.match(JSON.stringify(response.json()), /not a web origin resource/)
  })
})

describe('routing', () => {
  test('an unknown path is 404 and names what it refused', async () => {
    const instance = await managed()
    const response = await http(instance.origin, { path: '/api/session.list', token: instance.token })
    assert.equal(response.status, 404)
    assert.match(JSON.stringify(response.json()), /no route for GET \/api\/session\.list/)
  })

  test('the RPC face is POST-only and the event face is GET-only', async () => {
    const instance = await managed()
    assert.equal((await http(instance.origin, { path: '/rpc', token: instance.token })).status, 404)
    assert.equal((await http(instance.origin, { method: 'POST', path: '/events', token: instance.token })).status, 404)
  })

  test('the /studio prefix is Studio\'s own, and it is not part of the forwarding face', async () => {
    const instance = await managed()
    const response = await http(instance.origin, { path: '/studio/surface', token: instance.token })
    assert.deepEqual(response.json(), SURFACE)
    assert.equal(instance.upstream.calls.length, 0)
  })
})

describe('POST /rpc (§2.2a)', () => {
  const post = (instance: Rig, body: unknown, contentType = 'application/json'): Promise<{ status: number; json(): unknown; headers: Record<string, string | string[] | undefined> }> =>
    http(instance.origin, {
      method: 'POST',
      path: '/rpc',
      token: instance.token,
      headers: { 'content-type': contentType },
      body: JSON.stringify(body),
    })

  test('the call is repacked into the official client-request envelope', async () => {
    const instance = await managed()
    instance.upstream.reply(() => ({ status: 200, body: { type: 'server-response', ok: true, payload: { sessions: [] } } }))
    const response = await post(instance, { method: 'session.list', params: { limit: 10 } })
    assert.equal(response.status, 200)
    assert.deepEqual(response.json(), { type: 'server-response', ok: true, payload: { sessions: [] } })

    const call = instance.upstream.calls[0]
    assert.equal(call?.path, '/api/session.list')
    assert.equal(call?.method, 'POST')
    assert.equal(call?.body.type, 'client-request')
    assert.equal(call?.body.method, 'session.list')
    assert.deepEqual(call?.body.payload, { limit: 10 })
    // An rpcId is minted per call so the host's own logs can correlate it.
    assert.match(String(call?.body.rpcId), /^[0-9a-f-]{36}$/)
  })

  test('missing params become an empty payload rather than undefined', async () => {
    const instance = await managed()
    await post(instance, { method: 'session.list' })
    assert.deepEqual(instance.upstream.calls[0]?.body.payload, {})
  })

  test('an upstream failure is relayed verbatim, status included', async () => {
    const instance = await managed()
    instance.upstream.reply(() => ({ status: 404, text: '{"error":{"code":"unknown-method"}}' }))
    const response = await post(instance, { method: 'session.teleport' })
    // A Studio-flavoured error here would be the first brick of a shadow API.
    assert.equal(response.status, 404)
    assert.deepEqual(response.json(), { error: { code: 'unknown-method' } })
  })

  test('the method name is shape-checked so it cannot escape the /api/ prefix', async () => {
    const instance = await managed()
    for (const method of ['../secret', 'session', 'session.list/../..', '/api/session.list', '', 'Session.list']) {
      const response = await post(instance, { method })
      assert.equal(response.status, 400, method)
    }
    assert.equal(instance.upstream.calls.length, 0)
    // It checks the shape only: the method table itself stays upstream's.
    assert.equal(RPC_METHOD_PATTERN.test('session.list'), true)
    assert.equal(RPC_METHOD_PATTERN.test('workspace.pickDirectory'), true)
  })

  test('a non-JSON content type is 415 and an unparsable body is 400', async () => {
    const instance = await managed()
    assert.equal((await post(instance, { method: 'session.list' }, 'text/plain')).status, 415)
    const broken = await http(instance.origin, {
      method: 'POST',
      path: '/rpc',
      token: instance.token,
      headers: { 'content-type': 'application/json' },
      body: '{not json',
    })
    assert.equal(broken.status, 400)
  })
})

describe('GET /events (§2.2b)', () => {
  test('a session event arrives with the documented body', async () => {
    const instance = await managed()
    await instance.upstream.opened(MUX)
    const client = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the SSE client to attach')

    instance.upstream.push(MUX, {
      type: 'session/event',
      sessionId: 'sess-1',
      event: { kind: 'message/appended', seq: 7 },
      view: { toolName: 'read' },
    })
    const [frame] = await client.waitFor(1)
    assert.equal(frame?.event, 'session')
    assert.equal(frame?.id, 1)
    assert.deepEqual(frame?.data, {
      sessionId: 'sess-1',
      seq: 7,
      event: { kind: 'message/appended', seq: 7 },
      view: { toolName: 'read' },
    })
    client.close()
  })

  test('the stream opens with a comment line, as the official one does', async () => {
    const instance = await managed()
    const client = openSse(instance.origin, { token: instance.token })
    await until(() => client.frames.length > 0, 'the opening comment')
    assert.equal(client.frames[0]?.comment, 'connected')
    client.close()
  })

  test('a non-session mux frame rides verbatim under its own event name', async () => {
    const instance = await managed()
    await instance.upstream.opened(MUX)
    const client = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the SSE client to attach')
    instance.upstream.push(MUX, { type: 'approval/requested', sessionId: 'sess-1', approvalId: 'ap-1', toolName: 'bash' })
    const [frame] = await client.waitFor(1)
    assert.equal(frame?.event, 'mux')
    assert.deepEqual(frame?.data, { type: 'approval/requested', sessionId: 'sess-1', approvalId: 'ap-1', toolName: 'bash' })
    client.close()
  })

  test('the host stream is fanned out under its own name', async () => {
    const instance = await managed()
    await instance.upstream.opened(HOST)
    const client = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the SSE client to attach')
    instance.upstream.push(HOST, { type: 'host/permission', granted: true })
    const [frame] = await client.waitFor(1)
    assert.equal(frame?.event, 'host')
    assert.deepEqual(frame?.data, { type: 'host/permission', granted: true })
    client.close()
  })

  test('two clients see the same ids: the upstream stream is consumed once', async () => {
    const instance = await managed()
    await instance.upstream.opened(MUX)
    const first = openSse(instance.origin, { token: instance.token })
    const second = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 2, 'both clients to attach')
    instance.upstream.push(MUX, { type: 'session/subscribed', sessionId: 'sess-1', lastSeq: 3 })
    await first.waitFor(1)
    await second.waitFor(1)
    assert.equal(first.events[0]?.id, second.events[0]?.id)
    assert.equal(instance.upstream.opens(MUX), 1)
    first.close()
    second.close()
    await until(() => instance.server.clients === 0, 'both clients to detach')
  })

  test('an unauthorized SSE attempt never becomes a client', async () => {
    const instance = await managed()
    const response = await http(instance.origin, { path: '/events', token: 'nope' })
    assert.equal(response.status, 401)
    assert.equal(instance.server.clients, 0)
  })
})

describe('resume (§2.3)', () => {
  test('Last-Event-ID replays exactly the missed frames', async () => {
    const instance = await managed()
    await instance.upstream.opened(MUX)
    const first = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the first client to attach')
    for (const seq of [1, 2, 3]) {
      instance.upstream.push(MUX, { type: 'session/event', sessionId: 'sess-1', event: { seq } })
    }
    await first.waitFor(3)
    first.close()
    await until(() => instance.server.clients === 0, 'the first client to detach')

    // The native side missed frames 2 and 3.
    const resumed = openSse(instance.origin, { token: instance.token, headers: { 'last-event-id': '1' } })
    const replayed = await resumed.waitFor(2)
    assert.deepEqual(replayed.map(frame => frame.id), [2, 3])
    resumed.close()
  })

  test('the cursor may also arrive as a query parameter', async () => {
    const instance = await managed()
    await instance.upstream.opened(MUX)
    const seed = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the seed client')
    instance.upstream.push(MUX, { type: 'session/event', sessionId: 's', event: { seq: 1 } })
    await seed.waitFor(1)
    seed.close()

    const resumed = openSse(instance.origin, { token: instance.token, path: '/events?lastEventId=0' })
    const replayed = await resumed.waitFor(1)
    assert.equal(replayed[0]?.id, 1)
    resumed.close()
  })

  test('a resume past the retention window is told to re-baseline, not handed a gap', async () => {
    const instance = await managed({ retention: 2 })
    await instance.upstream.opened(MUX)
    const seed = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the seed client')
    for (const seq of [1, 2, 3, 4]) {
      instance.upstream.push(MUX, { type: 'session/event', sessionId: 's', event: { seq } })
    }
    await seed.waitFor(4)
    seed.close()

    const resumed = openSse(instance.origin, { token: instance.token, headers: { 'last-event-id': '1' } })
    const [gap] = await resumed.waitFor(1)
    assert.equal(gap?.event, 'studio/replay-gap')
    assert.deepEqual(gap?.data, { requested: 1, oldest: 3, retention: 2, advice: 'session.history' })
    resumed.close()
  })

  test('a resume that missed nothing replays nothing', async () => {
    const instance = await managed()
    await instance.upstream.opened(MUX)
    const seed = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the seed client')
    instance.upstream.push(MUX, { type: 'session/event', sessionId: 's', event: { seq: 1 } })
    await seed.waitFor(1)
    seed.close()

    const resumed = openSse(instance.origin, { token: instance.token, headers: { 'last-event-id': '1' } })
    await until(() => resumed.frames.length > 0, 'the opening comment')
    assert.deepEqual(resumed.events, [])
    resumed.close()
  })

  test('the health endpoint publishes the cursor high-water mark', async () => {
    const instance = await managed()
    await instance.upstream.opened(MUX)
    const client = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the client')
    instance.upstream.push(MUX, { type: 'session/event', sessionId: 's', event: { seq: 1 } })
    await client.waitFor(1)
    const health = await http(instance.origin, { path: '/studio/health', token: instance.token })
    assert.deepEqual(health.json(), { ok: true, clients: 1, cursor: 1, retention: 1024 })
    client.close()
  })
})

describe('upstream stream loss (§2.3)', () => {
  test('an ended upstream stream is announced and then reopened', async () => {
    const instance = await managed({ reopenDelayMs: 20 })
    await instance.upstream.opened(MUX)
    const client = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the client')

    instance.upstream.endStream(MUX)
    const [announcement] = await client.waitFor(1)
    // A silent stop looks exactly like an idle agent; the host must be told.
    assert.equal(announcement?.event, 'studio/upstream-closed')
    assert.deepEqual(announcement?.data, { path: MUX, retryInMs: 20 })
    await until(() => instance.upstream.opens(MUX) >= 2, 'the stream to reopen')
    client.close()
  })
})

describe('the handshake file (§2.1)', () => {
  let directory = ''

  before(() => { directory = mkdtempSync(join(tmpdir(), 'studio-handshake-')) })
  after(() => { rmSync(directory, { recursive: true, force: true }) })

  test('it is written 0600, in a 0700 directory, and it round-trips', () => {
    const path = join(directory, 'nested', 'bridge.json')
    const handshake = {
      host: LOOPBACK_ADDRESS,
      port: 43180,
      origin: 'http://127.0.0.1:43180',
      token: mintToken(),
      protocol: 1,
      pid: 4242,
      webUrl: 'http://127.0.0.1:3080',
    }
    const remove = writeHandshakeFile(path, handshake)
    try {
      assert.deepEqual(JSON.parse(readFileSync(path, 'utf8')), handshake)
      // The token is a bearer credential: nobody else on the machine may read it.
      assert.equal(statSync(path).mode & 0o777, 0o600)
      assert.equal(statSync(join(directory, 'nested')).mode & 0o777, 0o700)
    } finally {
      remove()
    }
    assert.throws(() => statSync(path), /ENOENT/)
  })

  test('the field table the native half decodes is written verbatim, webUrl included', () => {
    const path = join(directory, 'fields.json')
    const remove = writeHandshakeFile(path, {
      host: LOOPBACK_ADDRESS,
      port: 43180,
      origin: 'http://127.0.0.1:43180',
      token: 'deadbeef',
      protocol: 1,
      pid: 7,
      webUrl: 'http://127.0.0.1:3080',
    })
    try {
      // Key set, not just values: the native `BridgeDescriptor` decodes exactly
      // `host`/`port`/`token`/`protocol`/`webUrl`, and a renamed key here is a
      // silent "runtime offline" screen over there.
      assert.deepEqual(Object.keys(JSON.parse(readFileSync(path, 'utf8')) as object).sort(),
        ['host', 'origin', 'pid', 'port', 'protocol', 'token', 'webUrl'])
    } finally {
      remove()
    }
  })

  test('a second write replaces the file rather than appending to it', () => {
    const path = join(directory, 'bridge.json')
    writeHandshakeFile(path, { host: LOOPBACK_ADDRESS, port: 1, origin: 'a', token: 'x', protocol: 1, pid: 1 })()
    const remove = writeHandshakeFile(path, { host: LOOPBACK_ADDRESS, port: 2, origin: 'b', token: 'y', protocol: 1, pid: 2 })
    try {
      assert.equal((JSON.parse(readFileSync(path, 'utf8')) as { port: number }).port, 2)
      // No `webUrl` key at all when the deployment configured none: the native
      // half must be able to tell "unpublished" from "the empty string".
      assert.equal('webUrl' in (JSON.parse(readFileSync(path, 'utf8')) as object), false)
    } finally {
      remove()
    }
  })

  test('removing an already-removed file is not an error (unload runs once, but idempotently)', () => {
    const path = join(directory, 'gone.json')
    const remove = writeHandshakeFile(path, { host: LOOPBACK_ADDRESS, port: 1, origin: 'a', token: 'x', protocol: 1, pid: 1 })
    remove()
    assert.equal(remove(), undefined)
  })
})

describe('shutdown', () => {
  test('close detaches every client and stops answering', async () => {
    const instance = await rig()
    const client = openSse(instance.origin, { token: instance.token })
    await until(() => instance.server.clients === 1, 'the client')
    await instance.server.close()
    assert.equal(instance.server.clients, 0)
    await assert.rejects(http(instance.origin, { path: '/studio/health', token: instance.token }), /ECONNREFUSED/)
    client.close()
  })
})
