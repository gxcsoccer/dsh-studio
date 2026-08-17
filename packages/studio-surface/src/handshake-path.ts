/**
 * Where the handshake file lives (bridge-contract.md §2.1).
 *
 * Its own module for one reason: `src/index.ts` imports an upstream **value**
 * (`toFetchHandler`) and is therefore only loadable inside the dsh process,
 * while this rule — which path the native half will read a token from — is
 * exactly the kind of thing that must be covered by an executable test.
 */

import type { HostContext } from './host-context.ts'

/** Relative location of the handshake file under the harness home. */
export const HANDSHAKE_SEGMENTS = ['studio', 'bridge.json'] as const

/**
 * Resolve where the handshake file goes.
 *
 * `$DSH_HOME` is never re-derived here: `ctx.dshHomePath` is the host's own
 * resolver (app-boot provides it), and a second implementation would drift the
 * day the precedence rules change. Where the host does not provide it, the
 * operator must name the file — an explicit error beats a token written to a
 * path the native half does not read.
 * @param ctx - host context.
 * @param configured - `bridge.tokenFile`, empty when unset.
 * @returns the absolute path of the handshake file.
 * @throws Error when neither source can name a path.
 */
export function resolveHandshakePath(ctx: HostContext, configured: string): string {
  if (configured !== '') return configured
  const resolver = ctx.dshHomePath
  if (resolver === undefined) {
    throw new Error(
      'cannot locate $DSH_HOME: this host does not provide ctx.dshHomePath, '
      + 'so studio-surface needs an explicit bridge.tokenFile',
    )
  }
  return resolver(...HANDSHAKE_SEGMENTS)
}
