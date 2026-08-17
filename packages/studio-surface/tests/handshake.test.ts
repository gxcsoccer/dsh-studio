/**
 * `apply()` — what actually lands in `bridge.json`.
 *
 * `shell-url.test.ts` pins the decision; this file pins the *wiring*, which is
 * where the previous bug really lived: the value was correct-looking
 * configuration that nobody ever compared against reality.
 *
 * Three wiring properties, each of which was a way to get this wrong:
 *   - the data channel must not wait for the browser carrier (ADR-0002: domain
 *     data outlives the Web shell, so `webServer` is picked up through
 *     `ctx.inject`, never through `export const inject`);
 *   - the carrier may arrive **before or after** the channel binds, and both
 *     orders must end with a truthful file;
 *   - unloading must leave nothing behind — a handshake resurrected by a late
 *     child fiber would point at a closed port, which is the same class of lie
 *     with the arrow reversed.
 */

import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, test } from 'node:test'
import type { ApiProxy } from '@deepseek-ai/dsh-host-apiproxy'
import { Config } from '../src/config.ts'
import { HANDSHAKE_SEGMENTS } from '../src/handshake-path.ts'
import type { Handshake } from '../src/bridge-server.ts'
import type { HostContext } from '../src/host-context.ts'
import type { WebCarrier } from '../src/shell-url.ts'
import { applySurface } from '../src/plugin.ts'
import { fakeUpstream, freePort } from './helpers.ts'

/**
 * `applySurface` under test, with the gateway seam filled by the same double
 * `bridge-server.test.ts` uses. `src/index.ts` itself is the composition root
 * and imports the upstream monorepo, so it is deliberately not loaded here —
 * that import is exactly what this seam exists to keep out of the tests.
 * @param ctx - the host context double.
 * @param cfg - resolved configuration.
 */
function apply(ctx: HostContext, cfg: Config): void {
  applySurface(ctx, cfg, () => fakeUpstream())
}

/** Temp `$DSH_HOME`s to clean up. */
const homes: string[] = []

afterEach(() => {
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true })
})

/** A host context double that lets the test drive the two fibers by hand. */
interface FakeHost {
  ctx: HostContext
  /** Service names the plugin declared as *optional* dependencies. */
  readonly injected: readonly string[][]
  /** Run the registered effect body (i.e. bind the data channel). */
  start(): Promise<void>
  /** Unwind the effect. */
  stop(): Promise<void>
  /** The `webServer` service showing up, whenever the composition gets to it. */
  provideCarrier(carrier: WebCarrier): void
  /** Path of the handshake file. */
  readonly handshakePath: string
  /** Parsed handshake, or undefined when the file is gone. */
  read(): Handshake | undefined
}

/**
 * Build the double.
 *
 * `apiProxy` is a bare stub: nothing in this file makes a request, and the
 * adapter above ignores it — this file is about which address gets written, not
 * about forwarding (that is `bridge-server.test.ts`).
 * @param home - temp directory standing in for `$DSH_HOME`.
 * @returns the double.
 */
function fakeHost(home: string): FakeHost {
  const injected: string[][] = []
  let effectBody: (() => Promise<() => Promise<void>>) | undefined
  let disposer: (() => Promise<void>) | undefined
  let child: ((ctx: HostContext) => void) | undefined

  const ctx: HostContext = {
    effect(execute) { effectBody = execute; return undefined },
    inject(services, childApply) {
      injected.push([...services])
      child = childApply
      return undefined
    },
    apiProxy: {} as unknown as ApiProxy,
    dshHomePath: (...segments: string[]) => join(home, ...segments),
  }

  const handshakePath = join(home, ...HANDSHAKE_SEGMENTS)
  return {
    ctx,
    injected,
    handshakePath,
    async start() {
      assert.notEqual(effectBody, undefined, 'apply() registered no effect')
      disposer = await (effectBody as () => Promise<() => Promise<void>>)()
    },
    async stop() {
      if (disposer === undefined) return
      await disposer()
      disposer = undefined
    },
    provideCarrier(carrier) {
      assert.notEqual(child, undefined, 'apply() never asked for the carrier')
      ctx.webServer = carrier
      ;(child as (ctx: HostContext) => void)(ctx)
    },
    read() {
      if (!existsSync(handshakePath)) return undefined
      return JSON.parse(readFileSync(handshakePath, 'utf8')) as Handshake
    },
  }
}

/**
 * A resolved config on a free port.
 * @param shellUrl - the `bridge.shellUrl` override under test.
 * @returns the config.
 */
async function config(shellUrl = ''): Promise<Config> {
  return new Config({ bridge: { port: await freePort(), shellUrl } } as unknown as Config)
}

/**
 * A fresh temp home.
 * @returns its path.
 */
function tempHome(): string {
  const home = mkdtempSync(join(tmpdir(), 'studio-handshake-'))
  homes.push(home)
  return home
}

describe('bridge.json publishes the port the shell is really served on', () => {
  test('the data channel does not wait for the browser carrier', async () => {
    const host = fakeHost(tempHome())
    apply(host.ctx, await config())
    await host.start()

    // The channel is up and the token is usable with no `webServer` anywhere:
    // an Electron composition (dist over file://) must still get its sidebar.
    const handshake = host.read()
    assert.notEqual(handshake, undefined)
    assert.equal(handshake?.host, '127.0.0.1')
    assert.equal(typeof handshake?.token, 'string')
    // …and the shell address is simply absent, not invented.
    assert.equal('webUrl' in (handshake as Handshake), false)
    // Optional dependency, declared the upstream way.
    assert.deepEqual(host.injected, [['webServer']])

    await host.stop()
  })

  test('a carrier arriving after the channel rewrites the file in place', async () => {
    const host = fakeHost(tempHome())
    apply(host.ctx, await config())
    await host.start()
    assert.equal(host.read()?.webUrl, undefined)

    host.provideCarrier({ host: '127.0.0.1', port: 3081 })

    const handshake = host.read()
    assert.equal(handshake?.webUrl, 'http://127.0.0.1:3081')
    // Everything else survived the rewrite — the native half re-reads this file
    // on every reconnect, so a rewrite that dropped the token would be a
    // self-inflicted 401.
    assert.equal(typeof handshake?.token, 'string')
    assert.equal(handshake?.pid, process.pid)

    await host.stop()
  })

  test('a carrier already present when we bind is published on the first write', async () => {
    const host = fakeHost(tempHome())
    apply(host.ctx, await config())
    // Cordis may activate the carrier's fiber before ours; then the child body
    // runs while the effect has not published anything yet.
    host.provideCarrier({ host: '0.0.0.0', port: 3082 })
    await host.start()

    // First write already truthful, and the wildcard bind translated.
    assert.equal(host.read()?.webUrl, 'http://127.0.0.1:3082')

    await host.stop()
  })

  test('an explicit shellUrl beats the carrier (proxy in front of the runtime)', async () => {
    const host = fakeHost(tempHome())
    apply(host.ctx, await config('https://studio.internal/dsh'))
    await host.start()
    assert.equal(host.read()?.webUrl, 'https://studio.internal/dsh')

    host.provideCarrier({ host: '127.0.0.1', port: 3081 })
    assert.equal(host.read()?.webUrl, 'https://studio.internal/dsh')

    await host.stop()
  })

  test('unload removes the file, and a late carrier does not resurrect it', async () => {
    const host = fakeHost(tempHome())
    apply(host.ctx, await config())
    await host.start()
    assert.notEqual(host.read(), undefined)

    await host.stop()
    assert.equal(existsSync(host.handshakePath), false)

    // Child fibers unwind in an order we do not control. A handshake written
    // after the server closed would send the native half at a dead port — the
    // very bug, inverted.
    host.provideCarrier({ host: '127.0.0.1', port: 3081 })
    assert.equal(existsSync(host.handshakePath), false)
  })
})
