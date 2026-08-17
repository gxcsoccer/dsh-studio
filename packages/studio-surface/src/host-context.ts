/**
 * The host context face `studio-surface` needs.
 *
 * Upstream attaches both members to `Context` by declaration merging
 * (`packages/host/apiproxy/src/index.ts` for `apiProxy`,
 * `packages/boot/app-boot/src/index.ts` for the `ctx.provide('dshHomePath', …)`
 * pair). This subtree states them as a plain extension instead, so the members
 * cannot leak onto the client half's `Context` — the two plugins share one
 * tsconfig program here, and a merged interface would be shared with it.
 */

import type { Context } from '@deepseek-ai/cordis'
import type { ApiProxy } from '@deepseek-ai/dsh-host-apiproxy'

/** A host context with the two services Studio reads. */
export interface HostContext extends Context {
  /** The official API gateway. Studio forwards onto it and adds nothing. */
  apiProxy: ApiProxy
  /**
   * Harness-home resolver. Optional upstream (a non-app-boot embedding never
   * provides it), which is why `resolveHandshakePath` demands an explicit
   * `bridge.tokenFile` instead of re-deriving `$DSH_HOME`.
   */
  dshHomePath?: (...segments: string[]) => string
}
