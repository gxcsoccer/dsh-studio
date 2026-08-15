/**
 * The browser half of the studio bundle.
 *
 * This is the first row in our client roster that is ours rather than the
 * official one, and it exists to close a gap the desktop makes worse: when the
 * runtime goes away, the surface simply stops responding. In a browser tab a
 * dead page at least looks like a dead page. Inside an app window it looks like
 * the agent is thinking, and the longer a turn legitimately takes, the longer
 * that misreading survives.
 *
 * Everything it needs is published: `ctx.connection.hostDescription` is an
 * observable whose snapshot is documented as "absent before connect and while
 * reconnecting", and whose subscription covers "description replacement and
 * connection loss".
 *
 * The same row also owns the page half of the private chrome channel — the
 * hook native menus call to open a workspace. That channel is ours, not a
 * Harness seam; without `webkit.messageHandlers.studio` it simply does not
 * attach, which is how browser dogfood keeps working.
 */
import { useSyncExternalStore } from 'react'

import { projectCatalog } from './catalog.js'
import { hideOfficialRail } from './hide-official-rail.js'
import { attachSurface } from './surface-channel.js'
import { handleSurfaceRequest } from './surface-methods.js'
import { createWedgedSessionCard } from './wedged-session.jsx'

/**
 * Cordis **service** names, not package names.
 *
 * The two `inject` lists mean different things and it is an easy and expensive
 * confusion: `dsh.client.inject` in package.json is the package-level load
 * edge the shell resolves, while this one is the service list a fiber waits on.
 * Putting package names here parks the plugin in PENDING forever — visibly, at
 * least: the shell refuses to boot and names the services it is waiting for.
 *
 * `layout` is required because it declares `shell.overlay`, and a slot cannot
 * be filled before it is declared. `workspaces` is the navigation face
 * `openWorkspace` calls; without it the chrome channel would attach and then
 * throw on the first ⌘O.
 */
export const inject = ['slots', 'layout', 'connection', 'sessions', 'workspaces']

export function apply(ctx) {
  const source = ctx.connection.hostDescription

  function RuntimeConnectionBanner() {
    const description = useSyncExternalStore(
      (onChange) => source.subscribe(onChange),
      () => source.getSnapshot(),
      () => undefined,
    )

    // A live description means a completed handshake on the current
    // generation. Say nothing then: a banner for a working connection is the
    // kind of noise that teaches people to ignore banners.
    if (description) return null

    return (
      <div role="status" aria-live="polite" style={styles.bar}>
        <span style={styles.dot} aria-hidden="true" />
        <span>与运行时的连接断开了，正在重连。这期间发出的消息不会送达。</span>
      </div>
    )
  }

  ctx.effect(
    () =>
      ctx.slots.register(
        { name: 'shell.overlay', id: 'studio-connection', order: 100 },
        RuntimeConnectionBanner,
      ),
    'studio: runtime connection banner',
  )

  // Sits with the composer because that is where the futile action is: a wedged
  // session looks exactly like a working one until you type into it.
  ctx.slots.inject('conversation.input.dock', () =>
    ctx.slots.register(
      { name: 'conversation.input.dock', id: 'studio-wedged-session', order: 10 },
      createWedgedSessionCard(ctx),
    ),
  )

  // Private chrome channel. Absent in a regular browser — `attachSurface`
  // returns null and the rest of the plugin is unchanged.
  const surface = attachSurface({
    async onRequest(frame) {
      return handleSurfaceRequest(ctx, frame)
    },
  })

  if (surface) {
    // Native chrome owns the session list and the settings door. Collapse
    // the official column, then zero its grid track: the settings modal is
    // position:fixed inside that tree, so the slot has to stay mounted.
    collapseOfficialSidebar(ctx)
    hideOfficialRail()

    ctx.effect(() => {
      const emit = () => {
        const sessions = ctx.sessions.list.getSnapshot()
        const workspaces = ctx.workspaces.list.getSnapshot()
        const row = sessions.current ? sessions.byId[sessions.current] : undefined
        surface.event('selection', {
          sessionId: sessions.current,
          path: row?.cwd,
          title: row?.displayTitle,
        })
        surface.event('catalog', projectCatalog(workspaces, sessions))
      }
      emit()
      const offSessions = ctx.sessions.list.subscribe(emit)
      const offWorkspaces = ctx.workspaces.list.subscribe(emit)
      return () => {
        offSessions()
        offWorkspaces()
      }
    }, 'studio: surface catalog')
  }
}

function collapseOfficialSidebar(ctx) {
  let done = false
  const attempt = () => {
    if (done) return
    try {
      ctx.layout.toggleSidebar()
      done = true
    } catch {
      // Root entry has not mounted yet; the layout face throws until then.
    }
  }
  attempt()
  if (!done) setTimeout(attempt, 200)
}

const styles = {
  bar: {
    position: 'absolute',
    top: 12,
    left: '50%',
    transform: 'translateX(-50%)',
    zIndex: 40,
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    padding: '7px 14px',
    borderRadius: 8,
    // Follows the host theme rather than hardcoding colours: the tokens are
    // what `ui-theme` projects onto the document, so this tracks light/dark
    // without knowing which is active.
    background: 'var(--dsw-color-background-elevated, #2b2b2b)',
    color: 'var(--dsw-color-text-primary, #f5f5f5)',
    border: '1px solid var(--dsw-color-border-default, rgba(255,255,255,0.14))',
    boxShadow: '0 6px 20px rgba(0,0,0,0.18)',
    font: '13px/1.4 -apple-system, BlinkMacSystemFont, system-ui, sans-serif',
    pointerEvents: 'none',
  },
  dot: {
    width: 7,
    height: 7,
    borderRadius: '50%',
    // Not colour alone: the sentence carries the meaning on its own.
    background: 'var(--dsw-color-status-warning, #e0a030)',
    flex: '0 0 auto',
  },
}
