import assert from 'node:assert/strict'
import { test } from 'node:test'

import { openWorkspace, pickSession } from '../src/open-workspace.js'

const workspace = (sessionIds = []) => ({
  workspaceId: 'ws-1',
  path: '/tmp/proj',
  sessionIds,
})

const list = (rows, current) => ({
  current,
  byId: Object.fromEntries(rows.map((row) => [row.id, row])),
})

const fake = ({ workspace: ws, sessions, connect }) => {
  const opened = []
  let connected = 0
  return {
    opened,
    get connected() {
      return connected
    },
    ctx: {
      workspaces: {
        create: async () => ws,
        connectWorkspace: async () => {
          connected += 1
          if (connect) return connect()
          throw new Error('connectWorkspace should not run')
        },
      },
      sessions: {
        list: { getSnapshot: () => sessions },
        open: (id) => opened.push(id),
      },
    },
  }
}

test('an empty path is rejected before any host call', async () => {
  await assert.rejects(() => openWorkspace({}, ''), /requires a path/)
  await assert.rejects(() => openWorkspace({}, null), /requires a path/)
})

test('already sitting in that workspace is a no-op open of the current session', async () => {
  const harness = fake({
    workspace: workspace(['a', 'b']),
    sessions: list(
      [
        { id: 'a', blank: false, updatedAt: 1 },
        { id: 'b', blank: false, updatedAt: 9 },
      ],
      'a',
    ),
  })
  const result = await openWorkspace(harness.ctx, '/tmp/proj')
  assert.deepEqual(result, { workspaceId: 'ws-1', sessionId: 'a' })
  assert.deepEqual(harness.opened, ['a'])
  assert.equal(harness.connected, 0)
})

test('otherwise the most recently updated non-blank session wins', async () => {
  const harness = fake({
    workspace: workspace(['old', 'blank', 'fresh']),
    sessions: list([
      { id: 'old', blank: false, updatedAt: 10 },
      { id: 'blank', blank: true, updatedAt: 50 },
      { id: 'fresh', blank: false, updatedAt: 40 },
    ]),
  })
  const result = await openWorkspace(harness.ctx, '/tmp/proj')
  assert.equal(result.sessionId, 'fresh')
  assert.deepEqual(harness.opened, ['fresh'])
  assert.equal(harness.connected, 0)
})

test('a workspace with only a blank session opens that blank rather than minting another', async () => {
  const harness = fake({
    workspace: workspace(['blank']),
    sessions: list([{ id: 'blank', blank: true, updatedAt: 1 }]),
  })
  assert.equal((await openWorkspace(harness.ctx, '/tmp/proj')).sessionId, 'blank')
  assert.deepEqual(harness.opened, ['blank'])
  assert.equal(harness.connected, 0)
})

test('nothing accounted means connectWorkspace, then open what it returns', async () => {
  const harness = fake({
    workspace: workspace([]),
    sessions: list([]),
    connect: async () => 'new-blank',
  })
  const result = await openWorkspace(harness.ctx, '/tmp/proj')
  assert.deepEqual(result, { workspaceId: 'ws-1', sessionId: 'new-blank' })
  assert.equal(harness.connected, 1)
  assert.deepEqual(harness.opened, ['new-blank'])
})

test('session ids that are not in the list yet do not count as openable', () => {
  assert.equal(pickSession(workspace(['ghost']), list([])), undefined)
})
