import assert from 'node:assert/strict'
import { test } from 'node:test'

import { diagnoseWedge } from '../src/diagnose.js'

/** Compact log builder — these tests are about sequences, not payload shapes. */
const log = (...rows) => rows
const call = (seq, callId) => ({ type: 'tool/call', seq, data: { callId } })
const result = (seq, callId) => ({
  type: 'tool/result',
  seq,
  data: { message: { source: { callId } } },
})
const turnEnd = (seq) => ({ type: 'turn/end', seq, data: {} })
const message = (seq) => ({ type: 'assistant/message', seq, data: {} })

test('a healthy log diagnoses nothing', () => {
  const events = log(message(1), call(2, 'a'), result(3, 'a'), turnEnd(4))
  assert.equal(diagnoseWedge(events), null)
})

test('a turn with no tools at all is healthy', () => {
  assert.equal(diagnoseWedge(log(message(1), turnEnd(2))), null)
})

test('an unanswered call wedges the log and anchors at the last clean turn', () => {
  const events = log(
    message(1),
    call(2, 'a'),
    result(3, 'a'),
    turnEnd(4), // clean
    message(5),
    call(6, 'orphan'),
    turnEnd(7), // wedged
  )
  assert.deepEqual(diagnoseWedge(events), { orphanSeq: 6, anchor: 4 })
})

test('wedged on the very first turn leaves nothing to cut from', () => {
  const events = log(message(1), call(2, 'orphan'), turnEnd(3))
  assert.deepEqual(diagnoseWedge(events), { orphanSeq: 2, anchor: null })
})

/**
 * Everything after the first orphan is already downstream of a request the
 * provider will not accept, so a later clean-looking turn must not be offered
 * as an anchor — forking there would carry the orphan along.
 */
test('turns after the orphan never become the anchor', () => {
  const events = log(
    call(1, 'a'),
    result(2, 'a'),
    turnEnd(3), // clean
    call(4, 'orphan'),
    turnEnd(5), // wedged
    call(6, 'b'),
    result(7, 'b'),
    turnEnd(8), // looks clean in isolation, is not
  )
  assert.deepEqual(diagnoseWedge(events), { orphanSeq: 4, anchor: 3 })
})

test('several calls in one turn are all matched before the turn counts as clean', () => {
  const events = log(
    call(1, 'a'),
    call(2, 'b'),
    result(3, 'a'),
    result(4, 'b'),
    turnEnd(5),
    call(6, 'c'),
    call(7, 'orphan'),
    result(8, 'c'),
    turnEnd(9),
  )
  assert.deepEqual(diagnoseWedge(events), { orphanSeq: 7, anchor: 5 })
})

/** A result may arrive in a later turn; the log is what matters, not the turn. */
test('a result in a later turn still settles the call', () => {
  const events = log(call(1, 'a'), turnEnd(2), result(3, 'a'), turnEnd(4))
  assert.deepEqual(diagnoseWedge(events), { orphanSeq: 1, anchor: null })
})

/** `session.history` wraps events; the raw form appears in fixtures and logs. */
test('accepts both the wrapped and the raw event form', () => {
  const wrapped = log(call(1, 'a'), result(2, 'a'), turnEnd(3)).map((event) => ({ event }))
  assert.equal(diagnoseWedge(wrapped), null)
})

test('a still-open turn is not treated as an anchor', () => {
  // No turn/end at the tail: the last call is in flight, not orphaned.
  const events = log(call(1, 'a'), result(2, 'a'), turnEnd(3), call(4, 'in-flight'))
  assert.equal(diagnoseWedge(events), null)
})
