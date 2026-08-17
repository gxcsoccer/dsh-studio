/**
 * `webUrl` — the handshake's shell address.
 *
 * WHAT THIS FILE PINS
 * -------------------
 * `bridge.json` used to say `http://127.0.0.1:3080` on a runtime that was
 * serving 3081, because the profile restated the web bundle's *default* port as
 * if it were an observation. The native half then loaded a dead URL into its
 * WKWebView — and a wrong address is worse than no address, because absence is
 * what triggers its retry loop and its "runtime offline" diagnostic.
 *
 * So the two properties worth nailing down are: **never invent a port**, and
 * **never publish an address we have not observed** (unless a human explicitly
 * configured one, which is a statement about a proxy we cannot see).
 */

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import { resolveShellUrl, type WebCarrier } from '../src/shell-url.ts'

/** A carrier that has finished listening. */
const listening = (port: number, host = '127.0.0.1'): WebCarrier => ({ host, port })

describe('resolveShellUrl: truth, override, or silence — never a guess', () => {
  test('nothing configured and no carrier → no webUrl at all', () => {
    assert.equal(resolveShellUrl({ configured: '' }), undefined)
    assert.equal(resolveShellUrl({ configured: '   ' }), undefined)
    assert.equal(resolveShellUrl({ configured: '', carrier: undefined }), undefined)
  })

  test('the carrier is the source of truth: whatever it listened on is published', () => {
    // The regression, stated: a runtime started with `--port 3081` must publish
    // 3081, not the bundle default.
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(3081) }), 'http://127.0.0.1:3081')
    // `port: 0` compositions get an OS-assigned port; the getter reports the
    // resolved one, so this is exactly the case config could never express.
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(54_321) }), 'http://127.0.0.1:54321')
  })

  test('no input produces 3080 — the old default is not compiled in anywhere', () => {
    const guesses = [
      resolveShellUrl({ configured: '' }),
      resolveShellUrl({ configured: '', carrier: listening(3081) }),
      resolveShellUrl({ configured: '', carrier: listening(43_180) }),
    ]
    assert.equal(guesses.some(url => url?.includes('3080') === true), false)
  })

  test('an explicit configuration wins: only a human knows about the proxy in front', () => {
    // A reverse proxy / SSH tunnel / container mapping is invisible from inside
    // the process, so the deployment's statement beats the local observation.
    assert.equal(
      resolveShellUrl({ configured: 'https://studio.internal/dsh', carrier: listening(3081) }),
      'https://studio.internal/dsh',
    )
    assert.equal(resolveShellUrl({ configured: '  http://127.0.0.1:9000  ' }), 'http://127.0.0.1:9000')
  })

  test('a carrier that is not listening yet publishes nothing (not port zero)', () => {
    // `Service.init` sets the port only after `listen` resolves. Reading it too
    // early must mean "ask again later", never `http://127.0.0.1:0`.
    const unset = { host: '127.0.0.1' } as unknown as WebCarrier
    assert.equal(resolveShellUrl({ configured: '', carrier: unset }), undefined)
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(0) }), undefined)
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(-1) }), undefined)
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(70_000) }), undefined)
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(3081.5) }), undefined)
    assert.equal(
      resolveShellUrl({ configured: '', carrier: { host: '127.0.0.1', port: Number.NaN } }),
      undefined,
    )
  })

  test('a wildcard bind is translated to loopback, because 0.0.0.0 is not connectable', () => {
    // `dsh --host 0.0.0.0` binds every interface; handing that literal to a
    // WKWebView is a connection error. The native half is on this machine by
    // construction (the data channel is loopback-only), so loopback is the
    // truthful translation rather than a guess.
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(3081, '0.0.0.0') }), 'http://127.0.0.1:3081')
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(3081, '::') }), 'http://127.0.0.1:3081')
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(3081, '') }), 'http://127.0.0.1:3081')
  })

  test('a non-wildcard host is kept verbatim', () => {
    assert.equal(resolveShellUrl({ configured: '', carrier: listening(3081, 'localhost') }), 'http://localhost:3081')
  })
})
