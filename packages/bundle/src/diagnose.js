/**
 * Decides whether a session log has wedged itself, and where a clean fork can
 * be cut from.
 *
 * Kept apart from the component and free of JSX so it can be tested directly:
 * this is the only part of the recovery that can be *wrong*. Rendering a card
 * nobody needed is noise; cutting at the wrong anchor silently discards work.
 */

/**
 * The authority is the log, not the error text.
 *
 * A wedged session is recognizable by structure — a `tool/call` whose `callId`
 * never gets a `tool/result` — and matching the provider's rejection wording
 * instead would break the day it is reworded or localized. The provider message
 * is the symptom; the orphan is the cause.
 *
 * @param events - session events in seq order, as `session.history` returns them.
 * @returns `null` when the session is healthy, otherwise the orphan's seq and
 *   the anchor to fork at (`null` anchor = nothing clean to cut from).
 */
export function diagnoseWedge(events) {
  const pending = new Map()
  const settled = new Set()
  let lastCleanTurnEnd
  let orphanSeq

  for (const entry of events) {
    const event = entry.event ?? entry
    if (event.type === 'tool/call') pending.set(event.data?.callId, event.seq)
    if (event.type === 'tool/result') {
      settled.add(event.data?.message?.source?.callId ?? event.data?.callId)
    }
    if (event.type !== 'turn/end') continue

    const orphan = [...pending].find(([callId]) => !settled.has(callId))
    if (orphan) {
      // Only the first one matters: everything after it is already downstream
      // of a request the provider will not accept.
      if (orphanSeq === undefined) orphanSeq = orphan[1]
    } else if (orphanSeq === undefined) {
      // `session.fork` anchors on "the first turn/end at or after atSeq", so a
      // turn that closed with every call answered is a safe cut point.
      lastCleanTurnEnd = event.seq
    }
  }

  if (orphanSeq === undefined) return null
  return { orphanSeq, anchor: lastCleanTurnEnd ?? null }
}
