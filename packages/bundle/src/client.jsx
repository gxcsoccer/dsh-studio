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
 */
import { useSyncExternalStore } from 'react'

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
 * be filled before it is declared.
 */
export const inject = ['slots', 'layout', 'connection']

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
