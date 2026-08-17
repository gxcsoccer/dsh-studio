/**
 * The host context face `studio-surface` needs.
 *
 * Stated structurally rather than as upstream's `Context`, for the same reason
 * the client half has `StudioContext`: the real `Context` is the whole Cordis
 * context with every host service merged onto it (sessions, llm, jobs, typert,
 * …), and this plugin is only allowed to touch a named few of them
 * (ARCHITECTURE.md §3). Naming exactly those makes the boundary a compile error
 * to cross and keeps the test doubles buildable.
 *
 * Every member really is upstream's, by declaration merging:
 *   - `apiProxy` — `@deepseek-ai/dsh-host-apiproxy` (`ApiProxyService` provides it);
 *   - `dshHomePath` — `@deepseek-ai/dsh-app-boot`, optional there too, because a
 *     non-app-boot embedding never provides it. That is why
 *     `resolveHandshakePath` demands an explicit `bridge.tokenFile` instead of
 *     re-deriving `$DSH_HOME` itself;
 *   - `webServer` — `@deepseek-ai/dsh-host-webserver`, optional and read for two
 *     scalars, so the handshake can publish the port the shell is *actually*
 *     served on instead of a compiled-in guess (`shell-url.ts`).
 *
 * {@link AssertHostContextFits} proves the real context still satisfies the
 * face, so an upstream rename lands here rather than at a user's first launch.
 *
 * ⚠️ With one honest exception: it proves **nothing about `webServer`**. That
 * member is optional *and* its provider (`@deepseek-ai/dsh-host-webserver`) is
 * not in this program — it is neither a dependency nor a transitive one, since
 * we only ever read it off a context somebody else composed. An absent optional
 * property satisfies `extends`, so a rename upstream would slip straight
 * through this assertion. Adding the package as a devDependency just to make
 * the check bite would pull a whole HTTP carrier in for two scalars.
 *
 * What catches it instead is that the degradation is **visible at runtime**:
 * `ctx.inject(['webServer'])` never fires → no `webUrl` in the handshake → the
 * native half logs "bridge.json 里没有 webUrl" and keeps re-discovering the
 * shell (`StudioEnvironment.noteOffline`) instead of loading a wrong page. The
 * failure mode is "no shell address", never a lie and never a crash — which is
 * the property that actually matters here (docs/known-gaps.md G-10).
 */

import type { Context, Disposable } from '@deepseek-ai/cordis'
import type { ApiProxy } from '@deepseek-ai/dsh-host-apiproxy'
// Type-only, and imported for its declaration merging alone: app-boot is what
// puts `dshHomePath` on `Context`, so without it in the program the assertion
// below could not see the member. Nothing of the boot package is imported at
// runtime — this plugin is loaded by it, not the other way round.
import type {} from '@deepseek-ai/dsh-app-boot'
import type { WebCarrier } from './shell-url.ts'

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
  /**
   * Run a child fiber once the named services exist — the upstream idiom for an
   * **optional** dependency (`api-proxy.ts` uses it for `sessionProjections`).
   *
   * It is deliberately not `export const inject`: cordis 4 has no
   * required/optional split there, so listing `webServer` as a hard dependency
   * would keep the data channel from ever starting in a composition that has no
   * browser carrier (Electron loads dist over `file://`). The domain data must
   * not wait on the Web shell — that is the whole point of ADR-0002.
   * @param services - service names to wait for.
   * @param apply - child body, receiving a context where they are present.
   */
  inject(services: string[], apply: (ctx: HostContext) => void): unknown
  /** The official API gateway. Studio forwards onto it and adds nothing. */
  apiProxy: ApiProxy
  /** Harness-home resolver; absent outside an app-boot launch (see above). */
  dshHomePath?: (...segments: string[]) => string
  /**
   * The official browser carrier, when the composition has one.
   *
   * Read for two scalars only (`host`, `port`) and only to publish a truthful
   * `webUrl`; see `shell-url.ts` for why guessing that port was a bug. Optional
   * because a non-web composition provides no such service — and because an
   * upstream rename must degrade to "no shell address published", never to a
   * crash on launch.
   */
  webServer?: WebCarrier
}

/** Compile-time assertion carrier. */
type Expect<T extends true> = T

/** @see HostContext */
export type AssertHostContextFits = Expect<Context extends HostContext ? true : false>
