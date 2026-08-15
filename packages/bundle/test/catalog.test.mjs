import assert from 'node:assert/strict'
import { test } from 'node:test'

import { projectCatalog } from '../src/catalog.js'

const workspace = (id, sessionIds, title = id) => ({
  workspaceId: id,
  title,
  path: `/${title}`,
  sessionIds,
})

const session = (id, extra = {}) => ({
  id,
  displayTitle: extra.title ?? id,
  blank: extra.blank ?? false,
  running: extra.running ?? false,
  updatedAt: extra.updatedAt ?? 0,
  origin: extra.origin,
})

test('groups accounted sessions under their workspace, newest first', () => {
  const catalog = projectCatalog(
    { items: [workspace('ws', ['old', 'fresh'])], archivedSessionIds: [] },
    {
      current: 'fresh',
      ids: ['old', 'fresh'],
      byId: {
        old: session('old', { updatedAt: 1, title: '旧的' }),
        fresh: session('fresh', { updatedAt: 9, title: '新的' }),
      },
    },
  )
  assert.equal(catalog.currentSessionId, 'fresh')
  assert.deepEqual(
    catalog.workspaces[0].sessions.map((row) => row.sessionId),
    ['fresh', 'old'],
  )
  assert.equal(catalog.workspaces[0].sessions[0].title, '新的')
  assert.deepEqual(catalog.ungrouped, [])
})

test('a blank draft stays visible only while it is current', () => {
  const workspaces = { items: [workspace('ws', ['talk', 'draft'])], archivedSessionIds: [] }
  const sessions = {
    current: 'draft',
    ids: ['talk', 'draft'],
    byId: {
      talk: session('talk', { title: '已有对话' }),
      draft: session('draft', { blank: true, title: '新会话' }),
    },
  }

  const onDraft = projectCatalog(workspaces, sessions)
  assert.deepEqual(
    onDraft.workspaces[0].sessions.map((row) => row.sessionId),
    ['talk', 'draft'],
  )

  const away = projectCatalog(workspaces, { ...sessions, current: 'talk' })
  assert.deepEqual(
    away.workspaces[0].sessions.map((row) => row.sessionId),
    ['talk'],
  )
})

test('archived and subagent rows stay out of the sidebar', () => {
  const catalog = projectCatalog(
    { items: [workspace('ws', ['keep', 'gone', 'child'])], archivedSessionIds: ['gone'] },
    {
      ids: ['keep', 'gone', 'child'],
      byId: {
        keep: session('keep'),
        gone: session('gone'),
        child: session('child', { origin: 'subagent' }),
      },
    },
  )
  assert.deepEqual(
    catalog.workspaces[0].sessions.map((row) => row.sessionId),
    ['keep'],
  )
})

test('没有 displayTitle 时退回 title，再退回 id', () => {
  const catalog = projectCatalog(
    { items: [workspace('ws', ['a', 'b'])], archivedSessionIds: [] },
    {
      ids: ['a', 'b'],
      byId: {
        a: { id: 'a', title: '仅 title', blank: false, updatedAt: 1 },
        b: { id: 'b', blank: false, updatedAt: 2 },
      },
    },
  )
  assert.equal(catalog.workspaces[0].sessions.find((row) => row.sessionId === 'a').title, '仅 title')
  assert.equal(catalog.workspaces[0].sessions.find((row) => row.sessionId === 'b').title, 'b')
})

test('empty stores project to an empty catalog', () => {
  assert.deepEqual(projectCatalog({}, { ids: [], byId: {} }), {
    currentSessionId: undefined,
    workspaces: [],
    ungrouped: [],
  })
})

test('sessions the registry does not account land in 未分组', () => {
  const catalog = projectCatalog(
    { items: [workspace('ws', [])], archivedSessionIds: [] },
    {
      ids: ['orphan'],
      byId: { orphan: session('orphan', { title: '无家可归' }) },
    },
  )
  assert.equal(catalog.ungrouped[0].sessionId, 'orphan')
  assert.equal(catalog.ungrouped[0].title, '无家可归')
})
