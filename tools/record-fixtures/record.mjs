#!/usr/bin/env node
/**
 * Records a real downlink into a test fixture.
 *
 * The Swift tests decode these frames and assert that none of them lands in an
 * `.unknown` branch. That is the check nothing else performs: codegen proves the
 * generated types match the *schemas*, and `dsh-probe` proves one happy path
 * runs, but only replaying real traffic proves the types cover what the runtime
 * actually emits — including the frames a happy path never produces.
 *
 * Re-record after an upstream bump. A frame that starts decoding as `.unknown`
 * is the earliest visible sign the contract moved.
 *
 *   node tools/record-fixtures/record.mjs [--url http://127.0.0.1:3099]
 *                                         [--cwd <dir>] [--out <file>]
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..', '..')

const args = process.argv.slice(2)
const argOf = (flag, fallback) => {
  const i = args.indexOf(flag)
  return i === -1 ? fallback : args[i + 1]
}
const base = argOf('--url', 'http://127.0.0.1:3099')
const cwd = argOf('--cwd', join(homedir(), 'Workspace'))
const out = argOf('--out', join(repo, 'app', 'Tests', 'Fixtures', 'mux-session.jsonl'))
const probeFile = join(homedir(), '.dsh-fixture-probe.tmp')

const call = async (method, payload) => {
  const rpcId = crypto.randomUUID()
  const response = await fetch(`${base}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'client-request', rpcId, method, payload }),
  })
  const body = await response.json()
  if (!body.result?.ok) throw new Error(`${method}: ${JSON.stringify(body.result?.error)}`)
  return body.result.value
}

const respond = (rpcId, value) =>
  fetch(`${base}/api/respond`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'client-response', rpcId, result: { ok: true, value } }),
  })

const frames = []
const socket = new WebSocket(`${base.replace(/^http/, 'ws')}/api/events.mux`)
const opened = new Promise((ok, fail) => {
  socket.addEventListener('open', ok, { once: true })
  socket.addEventListener('error', fail, { once: true })
})

let sessionId
let finished
const done = new Promise((ok) => (finished = ok))

socket.addEventListener('message', async (event) => {
  const text = typeof event.data === 'string' ? event.data : new TextDecoder().decode(event.data)
  frames.push(text)
  const message = JSON.parse(text)
  const frame = message.payload

  // Approvals are answered so the turn actually completes: an abandoned
  // approval would leave the tail of the fixture missing every frame that comes
  // after it, which is exactly the part worth covering.
  if (frame?.type === 'approval/requested' && frame.sessionId === sessionId) {
    console.log('  approval →  allowed-once')
    await respond(message.rpcId, {
      sessionId: frame.sessionId,
      approvalId: frame.approvalId,
      outcome: 'allowed-once',
    })
  }
  if (
    frame?.type === 'session/event' &&
    frame.sessionId === sessionId &&
    frame.event?.type === 'turn/end'
  ) {
    finished()
  }
})

await opened
console.log(`recording     ${base}`)

const created = await call('session.create', { cwd })
sessionId = created.sessionId
console.log(`session       ${sessionId}`)

// A prompt chosen to exercise the awkward frames, not the easy ones: streamed
// text, a tool call, a sandbox denial, an escalation, an approval round trip,
// and a completed turn.
await call('session.prompt', {
  sessionId,
  mode: 'queue',
  content: [
    {
      type: 'text',
      text:
        'Run exactly this bash command and tell me whether it succeeded: ' +
        `printf ok > "${probeFile}"`,
    },
  ],
})

const timeout = setTimeout(() => {
  console.error('超时：没有等到 turn/end，fixture 可能不完整')
  finished()
}, 180_000)
await done
clearTimeout(timeout)
socket.close()

mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, frames.join('\n') + '\n')

const kinds = new Map()
for (const line of frames) {
  const type = JSON.parse(line).payload?.type ?? '?'
  kinds.set(type, (kinds.get(type) ?? 0) + 1)
}
console.log(`\n${frames.length} 帧 → ${out}`)
for (const [type, count] of [...kinds].sort((a, b) => b[1] - a[1])) {
  console.log(`  ${String(count).padStart(5)}  ${type}`)
}
console.log(`\n清理：rm -f ${probeFile}`)
