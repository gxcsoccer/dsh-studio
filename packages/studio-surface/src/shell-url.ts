/**
 * Where the official Web shell lives — the handshake's `webUrl`.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * `webUrl` used to be pure configuration, and the `studio` profile filled it in
 * with `http://127.0.0.1:3080` — the web bundle's *default* port. That is a
 * guess dressed up as a fact: `dsh --port 3081` (what `scripts/dogfood.sh`
 * does), a `port: 0` composition, or a busy 3080 all move the real server while
 * the published address keeps pointing at a port nobody serves. The native half
 * then loads a dead URL into its WKWebView and shows a blank window, which is
 * strictly worse than publishing nothing at all: absence triggers its retry
 * loop and its "runtime offline" diagnostic, a wrong value triggers neither.
 *
 * It is the same failure mode as the one the sidebar had (a confident-looking
 * answer produced without the data to back it), so it gets the same fix: derive
 * the value from the thing that actually knows, and when nothing knows, say
 * nothing.
 *
 * WHO ACTUALLY KNOWS
 * ------------------
 * The `webServer` service — it owns the socket, and its `port` getter reports
 * the *listened* port, already resolved when the composition asked for `0`.
 * Reading it is not a boundary violation: we read two scalars off a host
 * service, exactly as we read `dshHomePath`, and we still register no route and
 * serve no file.
 *
 * What the carrier cannot know is a reverse proxy, an SSH tunnel or a container
 * port mapping in front of it. That is what `bridge.shellUrl` stays for, and it
 * therefore **wins** — an explicit deployment statement beats a local
 * observation.
 */

import { LOOPBACK_ADDRESS } from './config.ts'

/**
 * The two scalars we read off the official browser carrier (`ctx.webServer`).
 *
 * Stated structurally for the same reason `HostContext` is: it keeps this
 * module executable, and the test doubles buildable, without the upstream
 * webserver package in the program.
 */
export interface WebCarrier {
  /** The configured bind host (`127.0.0.1` or `0.0.0.0`). */
  readonly host: string
  /** The listened port — the OS-assigned value when the composition asked for `0`. */
  readonly port: number
}

/** Highest port number a URL can name. */
const MAX_PORT = 65535

/**
 * The address the native half should load, or `undefined` when we do not know.
 *
 * Precedence: explicit configuration, then the listening carrier, then nothing.
 * There is no compiled-in default port anywhere in this function — a guessed
 * port is the bug this file exists to prevent.
 * @param options - the configured override and the carrier, if there is one.
 * @param options.configured - `bridge.shellUrl`; empty means "not configured".
 * @param options.carrier - the official browser carrier, when composed.
 * @returns an absolute URL, or `undefined` to omit `webUrl` from the handshake.
 */
export function resolveShellUrl(options: {
  configured: string
  carrier?: WebCarrier | undefined
}): string | undefined {
  const configured = options.configured.trim()
  if (configured !== '') return configured
  const carrier = options.carrier
  if (carrier === undefined) return undefined
  const port = carrier.port
  // Not yet listening (or a shape we do not recognise): `Service.init` sets the
  // port only after `listen` resolves, so an unset value here means "ask again
  // later", not "port zero".
  if (!Number.isInteger(port) || port <= 0 || port > MAX_PORT) return undefined
  return `http://${connectableHost(carrier.host)}:${port}`
}

/**
 * The host a client on this machine can actually connect to.
 *
 * `0.0.0.0` is a bind wildcard, not an address: handing it to a WebView yields
 * a connection error on macOS. The native half is by construction on the same
 * machine as the runtime (the data channel is loopback-only, §5), so loopback
 * is the truthful translation.
 * @param host - the carrier's configured bind host.
 * @returns the host to publish.
 */
function connectableHost(host: string): string {
  if (host === '' || host === '0.0.0.0' || host === '::') return LOOPBACK_ADDRESS
  return host
}
