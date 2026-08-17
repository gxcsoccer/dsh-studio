/**
 * The host context face `studio-surface` needs.
 *
 * Stated structurally rather than as upstream's `Context`, for the same reason
 * the client half has `StudioContext`: the real `Context` is the whole Cordis
 * context with every host service merged onto it (sessions, llm, jobs, typert,
 * …), and this plugin is only allowed to touch two of them plus `ctx.effect`
 * (ARCHITECTURE.md §3). Naming exactly those three makes the boundary a
 * compile error to cross and keeps the test doubles buildable.
 *
 * Both members really are upstream's, by declaration merging:
 *   - `apiProxy` — `@deepseek-ai/dsh-host-apiproxy` (`ApiProxyService` provides it);
 *   - `dshHomePath` — `@deepseek-ai/dsh-app-boot`, optional there too, because a
 *     non-app-boot embedding never provides it. That is why
 *     `resolveHandshakePath` demands an explicit `bridge.tokenFile` instead of
 *     re-deriving `$DSH_HOME` itself.
 *
 * {@link AssertHostContextFits} proves the real context still satisfies the
 * face, so an upstream rename lands here rather than at a user's first launch.
 */

import type { Context, Disposable } from '@deepseek-ai/cordis'
import type { ApiProxy } from '@deepseek-ai/dsh-host-apiproxy'
// Type-only, and imported for its declaration merging alone: app-boot is what
// puts `dshHomePath` on `Context`, so without it in the program the assertion
// below could not see the member. Nothing of the boot package is imported at
// runtime — this plugin is loaded by it, not the other way round.
import type {} from '@deepseek-ai/dsh-app-boot'

/** A host context with the three things Studio's host half uses. */
export interface HostContext {
  /**
   * Register the one reversible resource this plugin owns (the data channel).
   * Only the async shape is declared, because that is what `apply` installs;
   * the return value is unused, so it is not restated (upstream's awaitable
   * disposer type is not exported).
   * @param execute - effect body resolving to its disposer.
   * @param label - diagnostics label shown in the effect tree.
   */
  effect(execute: () => Promise<Disposable<Promise<void>>>, label?: string): unknown
  /** The official API gateway. Studio forwards onto it and adds nothing. */
  apiProxy: ApiProxy
  /** Harness-home resolver; absent outside an app-boot launch (see above). */
  dshHomePath?: (...segments: string[]) => string
}

/** Compile-time assertion carrier. */
type Expect<T extends true> = T

/** @see HostContext */
export type AssertHostContextFits = Expect<Context extends HostContext ? true : false>
