/**
 * Test doubles for the client half.
 *
 * The two interesting ones are {@link fakeSlots} and {@link fakeContext}: they
 * model the upstream behaviours Studio actually leans on — priority-per-cell
 * occupancy, one declarer per slot, deferred registration through `inject`,
 * and reversible `effect` — so a test can prove the manifest rules against
 * those semantics without the dsh monorepo installed. Where upstream throws,
 * the double throws with the same message shape, because
 * `classifyRegisterFailure` reads those messages.
 */

import type { BridgeTransport, TimerSeam } from '../src/client/bridge.ts'
import type {
  DynamicRegisterOptions, DynamicSlots, LiveSlotNode, SlotInjectionEffect, SlotSpecLike,
  StoredEntry, StudioContext,
} from '../src/client/upstream.ts'

/** A control-channel envelope as it left the Web side. */
export interface SentEnvelope {
  v: number
  t: 'req' | 'res' | 'evt'
  id?: string
  m?: string
  ok?: boolean
  p?: Record<string, unknown>
  e?: { code: string; message: string; retryable: boolean }
}

/** Transport double that records what was posted. */
export interface RecordingTransport extends BridgeTransport {
  readonly sent: SentEnvelope[]
  /** Envelopes of one method, in order. */
  ofMethod(method: string): SentEnvelope[]
  /** Last envelope of one method. */
  last(method: string): SentEnvelope | undefined
  clear(): void
}

/**
 * @returns a transport that keeps every posted envelope.
 */
export function recordingTransport(): RecordingTransport {
  const sent: SentEnvelope[] = []
  return {
    sent,
    post(json) { sent.push(JSON.parse(json) as SentEnvelope) },
    ofMethod(method) { return sent.filter(envelope => envelope.m === method) },
    last(method) { return sent.filter(envelope => envelope.m === method).at(-1) },
    clear() { sent.length = 0 },
  }
}

/** Manually driven timers, so a 5s timeout costs no wall-clock time. */
export interface ManualTimers extends TimerSeam {
  /** Fire every pending timer whose delay is at most `ms`. */
  advance(ms: number): void
  readonly pending: number
}

/**
 * @returns a timer seam under test control.
 */
export function manualTimers(): ManualTimers {
  const scheduled = new Map<number, { handler: () => void; ms: number }>()
  let next = 0
  return {
    setTimeout(handler, ms) {
      next += 1
      scheduled.set(next, { handler, ms })
      return next
    },
    clearTimeout(handle) { scheduled.delete(handle as number) },
    advance(ms) {
      for (const [handle, entry] of [...scheduled]) {
        if (entry.ms > ms) continue
        scheduled.delete(handle)
        entry.handler()
      }
    },
    get pending() { return scheduled.size },
  }
}

/** One registration on the fake ledger. */
interface FakeEntry extends StoredEntry {
  component: unknown
  slot: string
  cell: string
}

/**
 * The fake `ctx.slots`, plus the affordances a test needs.
 *
 * It implements {@link DynamicSlots} — the same dynamically keyed face the
 * production code consumes — so the double cannot drift from what Studio
 * actually calls, while the drift guards in `upstream.ts` keep that face tied to
 * the installed upstream package.
 */
export interface FakeSlots extends DynamicSlots {
  /** Model an official declaration (`children` of some registration upstream). */
  declare(slot: string, spec: SlotSpecLike, options?: { parent?: string }): void
  /** Model the official occupant of a slot. */
  occupy(slot: string, options?: { priority?: number; key?: string; id?: string; by?: string; children?: Record<string, SlotSpecLike> }): () => void
  /** Every registration, in insertion order. */
  readonly all: readonly FakeEntry[]
  /** Fire the entry-error hook, as upstream does on a render failure. */
  emitEntryError(slot: string, entry: StoredEntry, error: unknown, info: { abdicated: boolean }): void
  /** Registrations of one cell, lowest priority (the winner) first. */
  cell(slot: string, axis?: { key?: string; id?: string }): FakeEntry[]
}

const cellKey = (slot: string, options: { key?: string; id?: string }): string =>
  options.key !== undefined ? `${slot}#key=${options.key}`
    : options.id !== undefined ? `${slot}#id=${options.id}`
      : slot

/**
 * Build a fake slot registry.
 * @returns the fake service.
 */
export function fakeSlots(): FakeSlots {
  const specs = new Map<string, SlotSpecLike>()
  const parents = new Map<string, string | undefined>()
  const entries: FakeEntry[] = []
  const waiting = new Map<string, Array<{ callback: () => SlotInjectionEffect; dispose?: () => void }>>()
  const errorHooks = new Set<(key: string, entry: StoredEntry, error: unknown, info: { abdicated: boolean }) => void>()

  /**
   * Upstream accepts either a disposer or a generator yielding several from an
   * injection body; the double normalizes both, so a test cannot pass something
   * upstream would accept and the double would not.
   * @param effect - what the injection callback returned.
   * @returns one disposer.
   */
  const collect = (effect: SlotInjectionEffect): (() => void) => {
    if (typeof effect === 'function') return effect
    const disposers = [...effect]
    return () => { for (const dispose of disposers.reverse()) dispose() }
  }

  const declare = (slot: string, spec: SlotSpecLike, options: { parent?: string } = {}): void => {
    if (specs.has(slot)) throw new Error(`slot "${slot}" is already declared`)
    specs.set(slot, spec)
    parents.set(slot, options.parent)
    for (const pending of waiting.get(slot) ?? []) pending.dispose = collect(pending.callback())
  }

  const undeclare = (slot: string): void => {
    specs.delete(slot)
    parents.delete(slot)
  }

  /** Registrations of one slot, lowest priority first (winner of each cell first). */
  const own = (slot: string): FakeEntry[] => entries
    .filter(entry => entry.slot === slot)
    .sort((left, right) => (left.options.priority ?? 0) - (right.options.priority ?? 0))

  const service: FakeSlots = {
    declare,

    occupy(slot, options = {}) {
      return service.register({
        name: slot,
        ...(options.priority === undefined ? {} : { priority: options.priority }),
        ...(options.key === undefined ? {} : { key: options.key }),
        ...(options.id === undefined ? {} : { id: options.id }),
        ...(options.children === undefined ? {} : { children: options.children }),
        registrant: options.by ?? 'official',
      }, () => null)
    },

    register(options: DynamicRegisterOptions, component: unknown) {
      const spec = specs.get(options.name)
      if (spec === undefined) throw new Error(`slot "${options.name}" is not declared`)
      const priority = options.priority ?? 0
      const cell = cellKey(options.name, options)
      const clash = entries.find(entry => entry.cell === cell && (entry.options.priority ?? 0) === priority)
      if (clash !== undefined) {
        throw new Error(
          `slot "${options.name}" already has an entry at priority ${priority} `
          + `(registered by ${clash.registrant ?? 'unknown'})`,
        )
      }
      // Upstream refuses a duplicate child declaration before it records
      // anything (`SlotCore.register`), so the double does too: a rejected
      // registration must leave no trace at all.
      for (const child of Object.keys(options.children ?? {})) {
        if (specs.has(child)) throw new Error(`slot "${child}" is already declared`)
      }
      const entry: FakeEntry = {
        slot: options.name,
        cell,
        component,
        options: {
          ...(options.key === undefined ? {} : { key: options.key }),
          ...(options.id === undefined ? {} : { id: options.id }),
          priority,
        },
        ...(options.children === undefined ? {} : { children: options.children }),
        ...(options.registrant === undefined ? {} : { registrant: options.registrant }),
      }
      entries.push(entry)
      // Children are declared AFTER the entry is on the ledger, exactly as
      // upstream does it (`rec.entries = next` precedes `notifyDeclaration`).
      // The order is observable: declaring a child fires the injections waiting
      // on it, so a takeover's own entry is always visible before the child
      // registrations it unblocks.
      const declared: string[] = []
      for (const [child, childSpec] of Object.entries(options.children ?? {})) {
        declare(child, childSpec, { parent: options.name })
        declared.push(child)
      }
      return () => {
        const index = entries.indexOf(entry)
        if (index >= 0) entries.splice(index, 1)
        for (const child of declared) undeclare(child)
      }
    },

    inject(key, callback) {
      if (specs.has(key)) {
        const dispose = collect(callback())
        return () => { dispose() }
      }
      const pending: { callback: () => SlotInjectionEffect; dispose?: () => void } = { callback }
      const queue = waiting.get(key) ?? []
      queue.push(pending)
      waiting.set(key, queue)
      return () => {
        pending.dispose?.()
        const index = queue.indexOf(pending)
        if (index >= 0) queue.splice(index, 1)
      }
    },

    entries(key) { return own(key) },

    entriesOfSlot(key) {
      // Upstream renders one entry per cell: the lowest priority wins.
      const winners = new Map<string, FakeEntry>()
      for (const entry of own(key)) {
        if (!winners.has(entry.cell)) winners.set(entry.cell, entry)
      }
      return [...winners.values()]
    },

    spec(key) { return specs.get(key) },

    snapshot(root) {
      const build = (slot: string): LiveSlotNode => {
        const spec = specs.get(slot)
        const children = [...parents.entries()]
          .filter(([, parent]) => parent === slot)
          .map(([child]) => build(child))
        return {
          name: slot,
          kind: spec?.kind ?? 'single',
          scope: spec?.scope ?? 'root',
          occupants: own(slot).map((entry, index) => ({
            priority: entry.options.priority ?? 0,
            active: index === 0,
            ...(entry.registrant === undefined ? {} : { registrant: entry.registrant }),
            ...(entry.options.key === undefined ? {} : { key: entry.options.key }),
            ...(entry.options.id === undefined ? {} : { id: entry.options.id }),
          })),
          children,
        }
      }
      if (root !== undefined) return [build(root)]
      return [...specs.keys()].filter(slot => parents.get(slot) === undefined).map(build)
    },

    subscribe() { return () => {} },

    onEntryError(fn) {
      errorHooks.add(fn)
      return () => { errorHooks.delete(fn) }
    },

    get all() { return entries },

    emitEntryError(slot, entry, error, info) {
      for (const hook of errorHooks) hook(slot, entry, error, info)
    },

    cell(slot, axis = {}) {
      const key = cellKey(slot, axis)
      return own(slot).filter(entry => entry.cell === key)
    },
  }
  return service
}

/**
 * A fake client context whose effects are inspectable and reversible.
 *
 * It extends {@link StudioContext}, not upstream's `ClientContext`: the latter
 * *is* the whole Cordis context with every client service merged onto it, so a
 * double would have to implement `typert`, `llm`, `remote`, `attachments` … to
 * satisfy one call to `ctx.effect`. `upstream.ts` proves the real context
 * satisfies the narrow face, which is what makes this double legitimate.
 */
export interface FakeContext extends StudioContext {
  slots: FakeSlots
  /** Labels of the effects still installed. */
  readonly effects: readonly string[]
  /** Dispose every effect, as a plugin unload does. */
  unload(): void
}

/**
 * Build a fake client context.
 * @param slots - the slot service double.
 * @returns the fake context.
 */
export function fakeContext(slots: FakeSlots = fakeSlots()): FakeContext {
  const installed = new Map<number, { label: string; dispose: () => void }>()
  let next = 0
  const context: FakeContext = {
    slots,
    // Only the synchronous shape, because that is all `StudioContext` exposes
    // and all the client half installs: registrations and receivers. Cordis's
    // async-effect branch belongs to the host half, which uses a real context.
    effect(execute, label = 'anonymous') {
      next += 1
      const handle = next
      installed.set(handle, { label, dispose: execute() })
      return async () => {
        const entry = installed.get(handle)
        if (entry === undefined) return
        installed.delete(handle)
        // Cordis runs a synchronous disposer synchronously; the manifest hot
        // switch depends on that, so the double does the same.
        await entry.dispose()
      }
    },
    get effects() { return [...installed.values()].map(entry => entry.label) },
    unload() {
      for (const [handle, entry] of [...installed].reverse()) {
        installed.delete(handle)
        void entry.dispose()
      }
    },
  }
  return context
}
