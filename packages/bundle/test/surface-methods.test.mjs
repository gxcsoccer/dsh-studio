import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handleSurfaceRequest } from '../src/surface-methods.js'

test('unknown method fails loud', async () => {
  await assert.rejects(
    () => handleSurfaceRequest({}, { method: 'invented' }),
    /unknown surface method: invented/,
  )
})

test('archiveSession / renameSession / forkSession 走到对的面', async () => {
  const archived = []
  const renamed = []
  const forked = []
  const opened = []
  const ctx = {
    workspaces: { archiveSession: async (id) => archived.push(id) },
    sessions: {
      binding: (id) => ({
        session: {
          rename: async (title) => {
            renamed.push([id, title])
            return { ok: true, value: { title, seq: 1 } }
          },
        },
      }),
      fork: async (opts) => {
        forked.push(opts)
        return 'child'
      },
      open: (id) => opened.push(id),
    },
  }

  assert.deepEqual(
    await handleSurfaceRequest(ctx, { method: 'archiveSession', payload: { sessionId: 's-1' } }),
    { sessionId: 's-1' },
  )
  assert.deepEqual(
    await handleSurfaceRequest(ctx, {
      method: 'renameSession',
      payload: { sessionId: 's-1', title: '  你好  ' },
    }),
    { sessionId: 's-1', title: '你好' },
  )
  assert.deepEqual(
    await handleSurfaceRequest(ctx, { method: 'forkSession', payload: { sessionId: 's-1' } }),
    { sessionId: 'child' },
  )
  assert.deepEqual(archived, ['s-1'])
  assert.deepEqual(renamed, [['s-1', '你好']])
  assert.deepEqual(forked, [{ sessionId: 's-1', increaseTitle: true }])
  assert.deepEqual(opened, ['child'])
})

test('openSession / openWorkspace 缺参会失败', async () => {
  await assert.rejects(
    () => handleSurfaceRequest({ sessions: { open() {} } }, { method: 'openSession', payload: {} }),
    /sessionId/,
  )
  await assert.rejects(
    () => handleSurfaceRequest({}, { method: 'openWorkspace', payload: {} }),
    /path/,
  )
})

test('openSettings 用注入的实现，方便没有 document 的测试', async () => {
  let called = 0
  await handleSurfaceRequest(
    {},
    { method: 'openSettings', payload: {} },
    { openSettings: () => {
      called += 1
      return {}
    } },
  )
  assert.equal(called, 1)
})
