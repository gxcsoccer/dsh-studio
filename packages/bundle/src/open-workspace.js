/**
 * Navigate the web surface to a workspace the native chrome just opened.
 *
 * `workspaces.create` is idempotent and returns the canonical row, so this
 * is safe to call after the native side has already registered the same path
 * — and it is the right call when it has not, because the client list store
 * is updated from the unary response rather than waiting for the host frame.
 *
 * "Open" is not "New Session". `connectWorkspace` only reuses a *blank*
 * session; if the project already has a conversation, landing there is what
 * a desktop Open means. We pick first, and only connect when there is nothing
 * accounted to open.
 */

export async function openWorkspace(ctx, path) {
  if (typeof path !== 'string' || path.length === 0) {
    throw new Error('openWorkspace requires a path')
  }

  const workspace = await ctx.workspaces.create({ path })
  const chosen = pickSession(workspace, ctx.sessions.list.getSnapshot())
  if (chosen) {
    ctx.sessions.open(chosen)
    return { workspaceId: workspace.workspaceId, sessionId: chosen }
  }

  const sessionId = await ctx.workspaces.connectWorkspace(workspace.workspaceId)
  ctx.sessions.open(sessionId)
  return { workspaceId: workspace.workspaceId, sessionId }
}

/**
 * @param {{ sessionIds?: string[] }} workspace
 * @param {{ current?: string, byId?: Record<string, { id: string, blank?: boolean, updatedAt?: number }> }} list
 * @returns {string | undefined}
 */
export function pickSession(workspace, list) {
  const byId = list.byId ?? {}
  const ids = (workspace.sessionIds ?? []).filter((id) => byId[id])
  if (list.current && ids.includes(list.current)) return list.current

  const ranked = ids
    .map((id) => byId[id])
    .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))
  return (ranked.find((row) => !row.blank) ?? ranked[0])?.id
}
