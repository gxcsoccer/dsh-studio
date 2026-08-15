import assert from 'node:assert/strict'
import { test } from 'node:test'

import { openSession, startSession } from '../src/open-session.js'

test('openSession rejects a missing id before touching the store', () => {
  assert.throws(() => openSession({ sessions: { open() {} } }, ''), /sessionId/)
})

test('openSession forwards the id to sessions.open', () => {
  const opened = []
  const result = openSession({ sessions: { open: (id) => opened.push(id) } }, 's-1')
  assert.deepEqual(opened, ['s-1'])
  assert.deepEqual(result, { sessionId: 's-1' })
})

test('startSession reuses the workspace blank via connectWorkspace', async () => {
  const connected = []
  const opened = []
  const ctx = {
    sessions: {
      open: (id) => opened.push(id),
      list: {
        getSnapshot: () => ({
          current: 'talk',
          byId: { talk: { id: 'talk', blank: false } },
        }),
      },
    },
    workspaces: {
      connectWorkspace: async (id) => {
        connected.push(id)
        return 'draft-1'
      },
      list: {
        getSnapshot: () => ({
          recentWorkspaceId: 'ws-recent',
          items: [{ workspaceId: 'ws-1', sessionIds: ['talk'] }],
        }),
      },
    },
  }

  const result = await startSession(ctx)
  assert.deepEqual(connected, ['ws-1'])
  assert.deepEqual(opened, ['draft-1'])
  assert.deepEqual(result, { sessionId: 'draft-1' })
})

test('startSession without a current session falls back to the recent workspace', async () => {
  const connected = []
  const ctx = {
    sessions: { open: () => {}, list: { getSnapshot: () => ({ current: undefined, byId: {} }) } },
    workspaces: {
      connectWorkspace: async (id) => {
        connected.push(id)
        return 'draft-2'
      },
      list: { getSnapshot: () => ({ recentWorkspaceId: 'ws-recent', items: [] }) },
    },
  }
  await startSession(ctx)
  assert.deepEqual(connected, ['ws-recent'])
})

test('startSession honours an explicit workspaceId', async () => {
  const connected = []
  const ctx = {
    sessions: {
      open: () => {},
      list: { getSnapshot: () => ({ current: 'talk', byId: { talk: { id: 'talk' } } }) },
    },
    workspaces: {
      connectWorkspace: async (id) => {
        connected.push(id)
        return 'draft-x'
      },
      list: {
        getSnapshot: () => ({ items: [{ workspaceId: 'ws-1', sessionIds: ['talk'] }] }),
      },
    },
  }
  const result = await startSession(ctx, 'ws-other')
  assert.deepEqual(connected, ['ws-other'])
  assert.deepEqual(result, { sessionId: 'draft-x' })
})

test('startSession with no workspace at all fails loud', async () => {
  const ctx = {
    sessions: {
      list: { getSnapshot: () => ({ current: undefined, byId: {} }) },
    },
    workspaces: {
      list: { getSnapshot: () => ({ items: [] }) },
    },
  }
  await assert.rejects(() => startSession(ctx), /needs a workspace/)
})
