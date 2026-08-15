/**
 * Session title and fork — the other two items on the official row menu.
 *
 * Rename goes through the session face (`binding(id).session.rename`), not a
 * workspaces method. Fork is `sessions.fork` then `open`, same as the
 * official sidebar: the child lands in the list, then becomes current.
 */

export async function renameSession(ctx, sessionId, title) {
  if (typeof sessionId !== 'string' || sessionId.length === 0) {
    throw new Error('renameSession requires a sessionId')
  }
  const next = typeof title === 'string' ? title.trim() : ''
  if (!next) {
    throw new Error('renameSession requires a title')
  }
  const session = ctx.sessions.binding(sessionId)?.session
  if (!session) {
    throw new Error(`unknown session "${sessionId}"`)
  }
  const result = await session.rename(next)
  if (!result?.ok) {
    throw new Error(result?.error?.message ?? 'rename failed')
  }
  return { sessionId, title: result.value?.title ?? next }
}

export async function forkSession(ctx, sessionId) {
  if (typeof sessionId !== 'string' || sessionId.length === 0) {
    throw new Error('forkSession requires a sessionId')
  }
  const childId = await ctx.sessions.fork({ sessionId, increaseTitle: true })
  ctx.sessions.open(childId)
  return { sessionId: childId }
}
