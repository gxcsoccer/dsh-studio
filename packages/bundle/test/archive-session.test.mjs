import assert from 'node:assert/strict'
import { test } from 'node:test'

import { archiveSession } from '../src/archive-session.js'

test('archiveSession rejects a missing id before touching the store', async () => {
  await assert.rejects(
    () => archiveSession({ workspaces: { archiveSession() {} } }, ''),
    /sessionId/,
  )
})

test('archiveSession forwards the id to workspaces.archiveSession', async () => {
  const archived = []
  const result = await archiveSession(
    { workspaces: { archiveSession: async (id) => archived.push(id) } },
    's-9',
  )
  assert.deepEqual(archived, ['s-9'])
  assert.deepEqual(result, { sessionId: 's-9' })
})
