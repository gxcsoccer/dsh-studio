/**
 * Session navigation the native chrome asks the page to perform.
 *
 * `sessions.open` fails loud on an unknown id — that is the official
 * contract, and we let it through so a stale sidebar row becomes an error
 * response rather than a silent no-op.
 */

export function openSession(ctx, sessionId) {
  if (typeof sessionId !== 'string' || sessionId.length === 0) {
    throw new Error('openSession requires a sessionId')
  }
  ctx.sessions.open(sessionId)
  return { sessionId }
}

/**
 * Open the workspace's draft session — reuse an existing blank, or mint one.
 *
 * This is `connectWorkspace`, not a fresh `sessions.create` every time.
 * Unused blanks are hidden from the catalog the moment they are not
 * current; minting another would just pile up invisible drafts.
 */
export async function startSession(ctx, workspaceId) {
  const target = workspaceId || inferWorkspace(ctx)
  if (!target) {
    throw new Error('startSession needs a workspace')
  }
  const sessionId = await ctx.workspaces.connectWorkspace(target)
  ctx.sessions.open(sessionId)
  return { sessionId }
}

function inferWorkspace(ctx) {
  const workspaces = ctx.workspaces.list.getSnapshot()
  const sessions = ctx.sessions.list.getSnapshot()
  const current = sessions.current
  const currentWorkspaceId =
    current === undefined
      ? undefined
      : workspaces.items.find((item) => item.sessionIds.includes(current))?.workspaceId
  return currentWorkspaceId ?? workspaces.recentWorkspaceId
}
