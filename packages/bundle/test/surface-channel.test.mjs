import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  attachSurface,
  encodeError,
  encodeEvent,
  encodeRequest,
  encodeResponse,
  nativeHandler,
  parseFrame,
  VERSION,
} from '../src/surface-channel.js'

test('request / response / event keep the v1 shape', () => {
  assert.deepEqual(encodeRequest('1', 'openWorkspace', { path: '/tmp' }), {
    v: VERSION,
    type: 'req',
    id: '1',
    method: 'openWorkspace',
    payload: { path: '/tmp' },
  })
  assert.deepEqual(encodeResponse('1', { sessionId: 's' }), {
    v: VERSION,
    type: 'res',
    id: '1',
    ok: true,
    value: { sessionId: 's' },
  })
  assert.deepEqual(encodeError('1', new Error('nope')), {
    v: VERSION,
    type: 'res',
    id: '1',
    ok: false,
    error: 'nope',
  })
  assert.deepEqual(encodeEvent('ready'), {
    v: VERSION,
    type: 'evt',
    method: 'ready',
    payload: {},
  })
})

test('parseFrame accepts JSON text and rejects other versions', () => {
  const frame = encodeRequest('9', 'openWorkspace', { path: '/' })
  assert.deepEqual(parseFrame(JSON.stringify(frame)), frame)
  assert.equal(parseFrame({ ...frame, v: 2 }), null)
  assert.equal(parseFrame({ v: 1, type: 'nope' }), null)
  assert.equal(parseFrame(null), null)
})

test('a regular browser has no native handler', () => {
  assert.equal(nativeHandler({}), null)
})

test('attachSurface is a no-op without webkit', () => {
  assert.equal(attachSurface({ onRequest: async () => ({}) }, {}), null)
})

test('attachSurface posts ready and answers a request', async () => {
  const posted = []
  const global = {
    webkit: { messageHandlers: { studio: { postMessage: (m) => posted.push(m) } } },
  }
  const surface = attachSurface(
    {
      async onRequest(frame) {
        return { echo: frame.payload.x }
      },
    },
    global,
  )

  assert.equal(posted[0].type, 'evt')
  assert.equal(posted[0].method, 'ready')
  assert.equal(global.__DSH_STUDIO__, surface)

  await surface.dispatch(encodeRequest('rpc-1', 'ping', { x: 7 }))

  assert.deepEqual(posted[1], encodeResponse('rpc-1', { echo: 7 }))
})

test('dispatch ignores events and responses', async () => {
  let called = 0
  const posted = []
  const global = {
    webkit: { messageHandlers: { studio: { postMessage: (m) => posted.push(m) } } },
  }
  const surface = attachSurface(
    { async onRequest() { called += 1 } },
    global,
  )
  await surface.dispatch(encodeEvent('ready'))
  await surface.dispatch(encodeResponse('1', {}))
  assert.equal(called, 0)
  assert.equal(posted.length, 1)
})

test('a thrown request becomes an error response', async () => {
  const posted = []
  const global = {
    webkit: { messageHandlers: { studio: { postMessage: (m) => posted.push(m) } } },
  }
  const surface = attachSurface(
    {
      async onRequest() {
        throw new Error('unknown surface method: noSuchThing')
      },
    },
    global,
  )

  await surface.dispatch(encodeRequest('rpc-2', 'noSuchThing', {}))

  assert.deepEqual(posted[1], encodeError('rpc-2', 'unknown surface method: noSuchThing'))
})
