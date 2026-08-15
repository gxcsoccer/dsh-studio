/**
 * Hide a session from grouping surfaces. The log stays; the row does not.
 *
 * This is the official workspaces face, not a gateway call from Swift.
 * Archiving the current session is supposed to drop selection into the
 * New Session view — that rule lives on the page, so chrome asks here.
 */

export async function archiveSession(ctx, sessionId) {
  if (typeof sessionId !== 'string' || sessionId.length === 0) {
    throw new Error('archiveSession requires a sessionId')
  }
  await ctx.workspaces.archiveSession(sessionId)
  return { sessionId }
}
