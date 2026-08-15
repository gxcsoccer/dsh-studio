/**
 * Page-side handlers for chrome-channel methods. Kept out of the React
 * plugin so the routing table can be tested without a document or webkit.
 */
import { archiveSession } from './archive-session.js'
import { openSession, startSession } from './open-session.js'
import { openSettings } from './open-settings.js'
import { openWorkspace } from './open-workspace.js'
import { forkSession, renameSession } from './session-edit.js'

export async function handleSurfaceRequest(ctx, frame, deps = {}) {
  const method = frame?.method
  const payload = frame?.payload ?? {}
  switch (method) {
    case 'openWorkspace':
      return openWorkspace(ctx, payload.path)
    case 'openSession':
      return openSession(ctx, payload.sessionId)
    case 'startSession':
      return startSession(ctx, payload.workspaceId)
    case 'openSettings':
      return (deps.openSettings ?? openSettings)(deps.document)
    case 'archiveSession':
      return archiveSession(ctx, payload.sessionId)
    case 'renameSession':
      return renameSession(ctx, payload.sessionId, payload.title)
    case 'forkSession':
      return forkSession(ctx, payload.sessionId)
    default:
      throw new Error(`unknown surface method: ${method}`)
  }
}
