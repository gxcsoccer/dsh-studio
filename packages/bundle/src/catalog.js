/**
 * Project the official client stores into the catalog the native sidebar
 * renders.
 *
 * The page already owns grouping, archive membership, blank-session bits and
 * display titles. Re-deriving those on the Swift side from `workspace.list` +
 * `session.list` would drift the first time either store grows a field. The
 * chrome channel just holds up a mirror.
 */

export function projectCatalog(workspaces, sessions) {
  const archived = new Set(workspaces.archivedSessionIds ?? [])
  const byId = sessions.byId ?? {}

  const row = (id) => {
    const item = byId[id]
    // A blank session is a draft, not a history row. Official lists keep
    // only the current one visible; the rest stay on the host for reuse.
    if (
      !item ||
      archived.has(id) ||
      item.origin === 'subagent' ||
      (item.blank && item.id !== sessions.current)
    ) {
      return null
    }
    return {
      sessionId: item.id,
      title: item.displayTitle || item.title || id,
      blank: !!item.blank,
      running: !!item.running,
      updatedAt: item.updatedAt ?? 0,
    }
  }

  const used = new Set()
  const groups = (workspaces.items ?? []).map((workspace) => {
    const list = (workspace.sessionIds ?? [])
      .map(row)
      .filter(Boolean)
      .sort((a, b) => b.updatedAt - a.updatedAt)
    for (const session of list) used.add(session.sessionId)
    return {
      workspaceId: workspace.workspaceId,
      title: workspace.title,
      path: workspace.path,
      sessions: list,
    }
  })

  const ungrouped = (sessions.ids ?? [])
    .filter((id) => !used.has(id))
    .map(row)
    .filter(Boolean)
    .sort((a, b) => b.updatedAt - a.updatedAt)

  return {
    currentSessionId: sessions.current,
    workspaces: groups,
    ungrouped,
  }
}
