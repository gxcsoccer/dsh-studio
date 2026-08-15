import assert from 'node:assert/strict'
import { test } from 'node:test'

import { forkSession, renameSession } from '../src/session-edit.js'

test('renameSession rejects a missing id or blank title', async () => {
  await assert.rejects(() => renameSession({ sessions: { binding() {} } }, '', 'x'), /sessionId/)
  await assert.rejects(() => renameSession({ sessions: { binding() {} } }, 's-1', '  '), /title/)
})

test('renameSession calls the session face and returns the accepted title', async () => {
  const renamed = []
  const ctx = {
    sessions: {
      binding: (id) => ({
        session: {
          rename: async (title) => {
            renamed.push([id, title])
            return { ok: true, value: { title, seq: 3 } }
          },
        },
      }),
    },
  }
  const result = await renameSession(ctx, 's-1', '  你好  ')
  assert.deepEqual(renamed, [['s-1', '你好']])
  assert.deepEqual(result, { sessionId: 's-1', title: '你好' })
})

test('renameSession fails loud when the session is unknown or the host rejects', async () => {
  await assert.rejects(
    () => renameSession({ sessions: { binding: () => undefined } }, 'missing', 'x'),
    /unknown session/,
  )
  const ctx = {
    sessions: {
      binding: () => ({
        session: {
          rename: async () => ({ ok: false, error: { message: 'taken' } }),
        },
      }),
    },
  }
  await assert.rejects(() => renameSession(ctx, 's-1', 'x'), /taken/)
})

test('forkSession rejects a missing id before touching the store', async () => {
  await assert.rejects(
    () => forkSession({ sessions: { fork() {}, open() {} } }, ''),
    /sessionId/,
  )
})

test('renameSession rejects a non-string title', async () => {
  await assert.rejects(
    () => renameSession({ sessions: { binding() {} } }, 's-1', 12),
    /title/,
  )
})

test('forkSession mints a child and opens it', async () => {
  const forked = []
  const opened = []
  const result = await forkSession(
    {
      sessions: {
        fork: async (opts) => {
          forked.push(opts)
          return 'child-1'
        },
        open: (id) => opened.push(id),
      },
    },
    's-9',
  )
  assert.deepEqual(forked, [{ sessionId: 's-9', increaseTitle: true }])
  assert.deepEqual(opened, ['child-1'])
  assert.deepEqual(result, { sessionId: 'child-1' })
})
