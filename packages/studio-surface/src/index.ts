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
 * monorepo installed.
 *
 * Lifetime: a single `ctx.effect`. Port and handshake file are released on
 * plugin unload and on profile hot-swap, which is the requirement in
 * bridge-contract.md §2.1 and the reason nothing here is a module-level
 * singleton.
 */

import { toFetchHandler } from '@deepseek-ai/dsh-host-apiproxy'
import { PROTOCOL_VERSION } from '@dsh-studio/studio-client/src/index.ts'
import { Config, LOOPBACK_ADDRESS, surfaceCensus, toWireManifest } from './config.ts'
import {
  mintToken, startBridgeServer, writeHandshakeFile, type SurfaceInfo,
} from './bridge-server.ts'
import { resolveHandshakePath } from './handshake-path.ts'
import type { HostContext } from './host-context.ts'

export { Config } from './config.ts'
export type { BridgeConfig, Placement, SlotEntry, SlotEntrySelf, SlotMode } from './config.ts'
export { surfaceCensus, toWireManifest } from './config.ts'
export {
  assertLoopback, mintToken, RPC_METHOD_PATTERN, startBridgeServer, writeHandshakeFile,
} from './bridge-server.ts'
export type { BridgeServer, BridgeServerOptions, Handshake, SurfaceInfo, UpstreamFetch } from './bridge-server.ts'
export { HANDSHAKE_SEGMENTS, resolveHandshakePath } from './handshake-path.ts'
export type { HostContext } from './host-context.ts'

/** Plugin name shown in the official activation audit. */
export const name = 'studio-surface'

/** The gateway is the only host service Studio consumes. */
export const inject = ['apiProxy']

/**
 * Start the data channel.
 * @param ctx - host context (`ctx.apiProxy` injected).
 * @param config - resolved configuration, manifest included.
 */
export function apply(ctx: HostContext, config: Config): void {
  ctx.effect(async () => {
    const token = mintToken()
    const surface = (): SurfaceInfo => ({
      protocol: PROTOCOL_VERSION,
      // Read per request: a `--patch` or a profile hot-swap changes the
      // manifest without restarting the channel.
      manifest: toWireManifest(config),
      compareHotkey: config.compareHotkey,
      census: surfaceCensus(config),
    })
    const server = await startBridgeServer({
      port: config.bridge.port,
      token,
      upstream: toFetchHandler(ctx.apiProxy),
      surface,
      retention: config.bridge.retention,
    })
    // Written only after `listen` succeeded: a handshake file pointing at a
    // port nobody serves is worse than no file at all.
    const removeHandshake = writeHandshakeFile(resolveHandshakePath(ctx, config.bridge.tokenFile), {
      host: LOOPBACK_ADDRESS,
      port: server.port,
      origin: server.origin,
      token,
      protocol: PROTOCOL_VERSION,
      pid: process.pid,
      // Absent, not empty, when unconfigured: the native half must be able to
      // tell "no shell address published" from "an address that is the empty
      // string", and it decides between waiting and its own env override.
      ...(config.bridge.shellUrl === '' ? {} : { webUrl: config.bridge.shellUrl }),
    })
    return async () => {
      removeHandshake()
      await server.close()
    }
  }, 'studio-surface: data channel')
}
