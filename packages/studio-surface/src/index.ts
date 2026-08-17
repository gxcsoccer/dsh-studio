/**
 * `studio-surface` — the Cordis host plugin that runs inside the dsh process.
 *
 * It owns two things and nothing else:
 *   - the **surface manifest** (`config.ts`), because putting it in a plugin
 *     `Config` is what makes hot rollback and user override free
 *     (surface-manifest.md §1/§6);
 *   - the **data channel** (`bridge-server.ts`), the loopback HTTP+SSE face
 *     that lets the native half read domain data without going through the
 *     WebView (ADR-0002).
 *
 * It does not touch the WebView, does not know a slot from a session, and adds
 * no RPC method of its own. The one upstream value it imports —
 * `toFetchHandler` — is imported *here*, in the composition root, so every
 * other module in this package stays executable without the upstream
 * monorepo installed. That is also why the wiring itself lives in
 * `plugin.ts` and receives the adapter as an argument: the handshake bug this
 * seam exists for has to be reachable from a test.
 */

import { toFetchHandler } from '@deepseek-ai/dsh-host-apiproxy'
import type { Config } from './config.ts'
import { applySurface } from './plugin.ts'
import type { HostContext } from './host-context.ts'

export { Config } from './config.ts'
export type { BridgeConfig, Placement, SlotEntry, SlotEntrySelf, SlotMode } from './config.ts'
export { surfaceCensus, toWireManifest } from './config.ts'
export {
  assertLoopback, mintToken, RPC_METHOD_PATTERN, startBridgeServer, writeHandshakeFile,
} from './bridge-server.ts'
export type { BridgeServer, BridgeServerOptions, Handshake, SurfaceInfo, UpstreamFetch } from './bridge-server.ts'
export { HANDSHAKE_SEGMENTS, resolveHandshakePath } from './handshake-path.ts'
export { resolveShellUrl } from './shell-url.ts'
export type { WebCarrier } from './shell-url.ts'
export { applySurface } from './plugin.ts'
export type { GatewayAdapter } from './plugin.ts'
export type { HostContext } from './host-context.ts'

/** Plugin name shown in the official activation audit. */
export const name = 'studio-surface'

/**
 * The gateway is the only host service Studio *requires*.
 *
 * `webServer` is deliberately absent: it is picked up through `ctx.inject`
 * inside {@link applySurface}, so a composition without a browser carrier still
 * gets its data channel (ADR-0002 — domain data never waits on the Web shell).
 */
export const inject = ['apiProxy']

/**
 * Start the data channel, bound to the real gateway.
 * @param ctx - host context (`ctx.apiProxy` injected).
 * @param config - resolved configuration, manifest included.
 */
export function apply(ctx: HostContext, config: Config): void {
  applySurface(ctx, config, toFetchHandler)
}
