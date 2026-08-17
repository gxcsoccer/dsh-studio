/**
 * The plugin body: how the data channel, the handshake file and the browser
 * carrier are wired together.
 *
 * Split out of `index.ts` for one reason — `index.ts` is the composition root
 * and imports `toFetchHandler` from the upstream monorepo, which makes it
 * *unloadable* outside a real dsh install (`handshake-path.ts` header). The
 * wiring here is exactly where the `webUrl` bug lived, so it has to be
 * reachable from a test. It therefore takes the gateway adapter as a parameter
 * instead of importing it: the one upstream value stays in the root, and the
 * decision "which address do we publish, and when" becomes executable on its
 * own (see `tests/handshake.test.ts`).
 *
 * Lifetime: a single `ctx.effect`. Port and handshake file are released on
 * plugin unload and on profile hot-swap, which is the requirement in
 * bridge-contract.md §2.1 and the reason nothing here is a module-level
 * singleton.
 */

import type { ApiProxy } from '@deepseek-ai/dsh-host-apiproxy'
import { PROTOCOL_VERSION } from '@dsh-studio/studio-client/src/index.ts'
import { type Config, LOOPBACK_ADDRESS, surfaceCensus, toWireManifest } from './config.ts'
import {
  mintToken, startBridgeServer, writeHandshakeFile,
  type SurfaceInfo, type UpstreamFetch,
} from './bridge-server.ts'
import { resolveHandshakePath } from './handshake-path.ts'
import { resolveShellUrl, type WebCarrier } from './shell-url.ts'
import type { HostContext } from './host-context.ts'

/** The gateway seam: upstream's `toFetchHandler`, or a test double of it. */
export type GatewayAdapter = (proxy: ApiProxy) => UpstreamFetch

/**
 * Start the data channel and keep `bridge.json` truthful.
 * @param ctx - host context (`ctx.apiProxy` injected).
 * @param config - resolved configuration, manifest included.
 * @param toUpstream - adapter turning the gateway into a fetch handler.
 */
export function applySurface(
  ctx: HostContext,
  config: Config,
  toUpstream: GatewayAdapter,
): void {
  // The shell address is published as soon as it is *known*, which may be
  // before or after the data channel binds. Both orders happen, so neither
  // half assumes it runs first: the effect reads whatever `carrier` holds,
  // and the child fiber republishes if it arrives later.
  let carrier: WebCarrier | undefined
  let republish: ((next: WebCarrier) => void) | undefined

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
      upstream: toUpstream(ctx.apiProxy),
      surface,
      retention: config.bridge.retention,
    })
    const path = resolveHandshakePath(ctx, config.bridge.tokenFile)
    // Written only after `listen` succeeded: a handshake file pointing at a
    // port nobody serves is worse than no file at all.
    const publish = (): (() => void) => {
      const webUrl = resolveShellUrl({ configured: config.bridge.shellUrl, carrier })
      return writeHandshakeFile(path, {
        host: LOOPBACK_ADDRESS,
        port: server.port,
        origin: server.origin,
        token,
        protocol: PROTOCOL_VERSION,
        pid: process.pid,
        // Absent, not empty, when unknown: the native half must be able to tell
        // "no shell address published" from "an address that is the empty
        // string", and it decides between waiting and its own env override. A
        // *wrong* address is the worst of the three — it defeats both.
        ...(webUrl === undefined ? {} : { webUrl }),
      })
    }
    let removeHandshake = publish()
    republish = (next) => {
      carrier = next
      // Rewrite in place. The native half re-reads `bridge.json` on every
      // reconnect and every shell-discovery tick, so a late-arriving address
      // reaches it without a relaunch.
      removeHandshake()
      removeHandshake = publish()
    }
    return async () => {
      // Cleared *before* the file goes away: a child fiber that unwinds after
      // us must not resurrect a handshake pointing at a closed port.
      republish = undefined
      removeHandshake()
      await server.close()
    }
  }, 'studio-surface: data channel')

  // Who knows where the Web shell is served: the carrier that owns the socket.
  // Not `export const inject`, so a carrier-less composition is not blocked —
  // it simply publishes no `webUrl` (see `shell-url.ts`).
  ctx.inject(['webServer'], (scoped) => {
    const next = scoped.webServer
    if (next === undefined) return
    carrier = next
    republish?.(next)
  })
}
