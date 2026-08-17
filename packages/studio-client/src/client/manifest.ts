/**
 * Surface manifest resolution — surface-manifest.md §4, all seven rules.
 *
 * The manifest is untrusted input from the host (bridge-contract.md §5), so it
 * is parsed before it is planned, and planning is a pure function of
 * (manifest × measured slot ledger). Registration itself lives behind the
 * {@link ManifestRuntime} seam so the rules can be tested without React or a
 * live Cordis fiber.
 *
 * Rule map (each rule has exactly one implementation site):
 *   1. unlisted slot = web ................ {@link planManifest} (iterates listed rows only)
 *   2. mode web = register nothing ........ {@link planManifest} (`released`, never `registrations`)
 *   3. mirrored registers at +1 ........... {@link priorityOf} / {@link MIRRORED_PRIORITY}
 *   4. native/retired at `priority` (-1) .. {@link priorityOf}
 *   5. keys/ids override the parent mode .. {@link expandCells}
 *   6. declaring is claiming, no partial .. {@link resolveChildren}
 *   7. takeover is bottom-up (G-2) ........ {@link resolveChildTakeover}
 */

import type { BridgeErrorCode, WireScope } from './bridge.ts'
import type { Placement } from './native-slot.tsx'
import { isRecord } from './payload.ts'
import type { ChildrenTable, SlotSpecLike, StoredEntry } from './upstream.ts'

/** Slot state machine (ARCHITECTURE.md §5, surface-manifest.md §2). */
export type SlotMode = 'web' | 'mirrored' | 'native' | 'retired'

/** Valid modes; a fifth state is deliberately impossible (surface-manifest.md §7). */
export const SLOT_MODES: readonly SlotMode[] = ['web', 'mirrored', 'native', 'retired']

/** Valid placements. */
export const PLACEMENTS: readonly Placement[] = ['evacuated', 'overlay']

/** Priority a `mirrored` entry registers at: HIGHER than the official 0 (rule 3). */
export const MIRRORED_PRIORITY = 1

/** Priority a shadowing entry registers at by default: LOWER than the official 0 (rule 4). */
export const DEFAULT_SHADOW_PRIORITY = -1

/**
 * Registrant label stamped on every Studio registration. It lives here rather
 * than in the composition root because rule 7 reads it off the live ledger to
 * recognise a cell Studio already took over.
 */
export const REGISTRANT = 'dsh-studio'

/** Modes in which Studio owns the cell and renders the native truth. */
export const OWNING_MODES: readonly SlotMode[] = ['native', 'retired']

/** A manifest row without its `keys` / `ids` nesting (surface-manifest.md §2 `SlotEntrySelf`). */
export interface SlotEntrySelf {
  mode?: SlotMode
  placement?: Placement
  priority?: number
}

/** A manifest row. */
export interface SlotEntry extends SlotEntrySelf {
  /** Per-key configuration; `keyed` slots only. */
  keys?: Record<string, SlotEntrySelf>
  /** Per-registration-id configuration; `list` slots only. */
  ids?: Record<string, SlotEntrySelf>
}

/** `slot → row`. */
export type Manifest = Record<string, SlotEntry>

/** One rejected row (never partially applied — rule 6). */
export interface Rejection {
  /** Cell identity: the slot name, or `slot#key=…` / `slot#id=…`. */
  cell: string
  slot: string
  /** Closed-set wire code (§1.5). */
  reason: BridgeErrorCode
  detail: string
}

/** A resolved registration: exactly one native view will exist per instance of it. */
export interface CellRegistration {
  /** Stable identity of the shadowed cell; also the key of its `ctx.effect`. */
  cell: string
  slot: string
  mode: Exclude<SlotMode, 'web'>
  placement: Placement
  priority: number
  scope: WireScope
  kind: SlotSpecLike['kind']
  /** Keyed cell key (`keyed` slots). */
  key?: string
  /** List cell id (`list` slots). */
  id?: string
  /** Child slots this registration declares itself (rule 6). */
  children: ChildrenTable
  /** Child slots already declared by the shadowed occupant, left in its ownership (rule 6). */
  inheritedChildren: string[]
}

/** Outcome of planning a manifest. */
export interface ManifestPlan {
  registrations: CellRegistration[]
  /** Cells that must NOT be registered (rule 1 & 2): official keeps the cell. */
  released: string[]
  rejected: Rejection[]
  /** Diagnostics that are neither an application nor a rejection. */
  notes: string[]
}

/** `{ applied, rejected }` as returned over the bridge (§1.1 handshake). */
export interface ConfigureResult {
  applied: string[]
  rejected: Rejection[]
  /** Additive diagnostics field (allowed by §4: new optional fields do not bump `v`). */
  notes: string[]
}

/** Read-only view of the live slot ledger plus the compile-time pinned contracts. */
export interface SlotEnvironment {
  /** `ctx.slots.spec` — the declared spec of a slot, undefined while undeclared. */
  spec(slot: string): SlotSpecLike | undefined
  /** `ctx.slots.entries` — the raw ledger of a slot (all priorities). */
  entries(slot: string): readonly StoredEntry[]
  /** Compile-time pinned contract of a slot we are allowed to take over. */
  pinned(slot: string): PinnedSlotContract | undefined
}

/**
 * Compile-time pinned contract of one slot (playbook §① "立契约"). Names are
 * pinned so a missing runtime declaration is detectable; specs are pinned so a
 * child slot can be declared verbatim even before its official declarer loads.
 */
export interface PinnedSlotContract {
  slot: string
  spec: SlotSpecLike
  /** Child slot names the official occupant declares. */
  childNames: readonly string[]
  /** Specs of those children, as transcribed from upstream. */
  childSpecs: Readonly<Record<string, SlotSpecLike>>
}

/** Registration seam: `index.ts` implements it with `ctx.effect(() => ctx.slots.register(…))`. */
export interface ManifestRuntime {
  env: SlotEnvironment
  /**
   * Install one registration.
   * @returns disposer removing the registration (and its child declarations).
   * @throws when upstream refuses the registration (same-priority cell clash,
   * undeclared target, duplicate child declaration).
   */
  install(registration: CellRegistration): () => void
  /** Diagnostics sink. */
  log?(message: string): void
}

/**
 * Validate one entry-self shape.
 * @param raw - untrusted value.
 * @param where - diagnostic path.
 * @returns the validated row.
 * @throws Error with a human-readable reason (mapped to `bad_payload`).
 */
function parseEntrySelf(raw: unknown, where: string): SlotEntrySelf {
  if (!isRecord(raw)) throw new Error(`${where} must be an object`)
  const out: SlotEntrySelf = {}
  if (raw.mode !== undefined) {
    const mode = SLOT_MODES.find(candidate => candidate === raw.mode)
    if (mode === undefined) throw new Error(`${where}.mode ${JSON.stringify(raw.mode)} is not one of ${SLOT_MODES.join('|')}`)
    out.mode = mode
  }
  if (raw.placement !== undefined) {
    const placement = PLACEMENTS.find(candidate => candidate === raw.placement)
    if (placement === undefined) throw new Error(`${where}.placement ${JSON.stringify(raw.placement)} is not one of ${PLACEMENTS.join('|')}`)
    out.placement = placement
  }
  if (raw.priority !== undefined) {
    if (typeof raw.priority !== 'number' || !Number.isInteger(raw.priority)) {
      throw new Error(`${where}.priority must be an integer`)
    }
    out.priority = raw.priority
  }
  return out
}

/**
 * Parse an untrusted manifest object.
 * @param raw - the `manifest` / `patch` payload member.
 * @returns the parsed manifest plus one rejection per malformed row.
 */
export function parseManifest(raw: unknown): { manifest: Manifest; rejected: Rejection[] } {
  const manifest: Manifest = {}
  const rejected: Rejection[] = []
  if (!isRecord(raw)) {
    return { manifest, rejected: [{ cell: '*', slot: '*', reason: 'bad_payload', detail: 'manifest must be an object' }] }
  }
  for (const [slot, value] of Object.entries(raw)) {
    try {
      const self = parseEntrySelf(value, slot)
      const entry: SlotEntry = { ...self }
      const row = value as Record<string, unknown>
      for (const nest of ['keys', 'ids'] as const) {
        const table = row[nest]
        if (table === undefined) continue
        if (!isRecord(table)) throw new Error(`${slot}.${nest} must be a dict`)
        const parsed: Record<string, SlotEntrySelf> = {}
        for (const [cell, cellValue] of Object.entries(table)) {
          parsed[cell] = parseEntrySelf(cellValue, `${slot}.${nest}.${cell}`)
        }
        entry[nest] = parsed
      }
      manifest[slot] = entry
    } catch (error) {
      rejected.push({
        cell: slot,
        slot,
        reason: 'bad_payload',
        detail: error instanceof Error ? error.message : String(error),
      })
    }
  }
  return { manifest, rejected }
}

/**
 * Rules 3 & 4 — priority is the whole shadowing mechanism.
 * @param mode - resolved mode of the cell.
 * @param priority - explicit priority from the manifest row.
 * @returns the priority to register at.
 */
export function priorityOf(mode: Exclude<SlotMode, 'web'>, priority: number | undefined): number {
  // Rule 3: mirrored registers ABOVE the official entry — it rides the cell as
  // a passenger and never wins the render right.
  if (mode === 'mirrored') return MIRRORED_PRIORITY
  // Rule 4: native / retired register below it and take the cell.
  return priority ?? DEFAULT_SHADOW_PRIORITY
}

/** One planned cell before children resolution. */
interface CellDraft {
  cell: string
  mode: Exclude<SlotMode, 'web'>
  placement: Placement
  priority: number
  key?: string
  id?: string
}

/** Cell identity string. */
function cellId(slot: string, axis: 'key' | 'id' | undefined, value: string | undefined): string {
  return axis === undefined || value === undefined ? slot : `${slot}#${axis}=${value}`
}

/**
 * Rule 5 — expand a manifest row into cells. `keys` / `ids` entries override
 * the parent `mode`; the parent `mode` is the default for cells they do not
 * list.
 *
 * The key/id domain is NOT enumerable from the slot declaration (upstream
 * carries it in types only), so the parent mode can only be applied to cells
 * that are either listed in the manifest or observed on the live ledger.
 * @param slot - slot name.
 * @param entry - manifest row.
 * @param kind - declared kind of the slot.
 * @param env - live ledger view.
 * @returns drafts (registrable cells) and released cells (`mode: web`).
 */
export function expandCells(
  slot: string,
  entry: SlotEntry,
  kind: SlotSpecLike['kind'],
  env: SlotEnvironment,
): { drafts: CellDraft[]; released: string[]; rejected: Rejection[] } {
  const drafts: CellDraft[] = []
  const released: string[] = []
  const rejected: Rejection[] = []
  const parentMode: SlotMode = entry.mode ?? 'web'
  const placementOf = (self: SlotEntrySelf): Placement => self.placement ?? entry.placement ?? 'evacuated'

  const push = (self: SlotEntrySelf, axis: 'key' | 'id' | undefined, value: string | undefined): void => {
    const mode = self.mode ?? parentMode
    const cell = cellId(slot, axis, value)
    // Rule 2: web registers nothing at all — not even an empty component,
    // which would win the cell and render blank.
    if (mode === 'web') {
      released.push(cell)
      return
    }
    drafts.push({
      cell,
      mode,
      placement: placementOf(self),
      priority: priorityOf(mode, self.priority ?? entry.priority),
      ...(axis === 'key' && value !== undefined ? { key: value } : {}),
      ...(axis === 'id' && value !== undefined ? { id: value } : {}),
    })
  }

  if (kind === 'keyed' || kind === 'list') {
    const axis = kind === 'keyed' ? 'key' : 'id'
    const table = (kind === 'keyed' ? entry.keys : entry.ids) ?? {}
    const foreign = kind === 'keyed' ? entry.ids : entry.keys
    if (foreign !== undefined && Object.keys(foreign).length > 0) {
      rejected.push({
        cell: slot,
        slot,
        reason: 'bad_payload',
        detail: `${kind === 'keyed' ? 'ids' : 'keys'} is meaningless on a ${kind} slot`,
      })
      return { drafts, released, rejected }
    }
    const observed = new Set(
      env.entries(slot)
        .map(candidate => (axis === 'key' ? candidate.options.key : candidate.options.id))
        .filter((value): value is string => value !== undefined),
    )
    for (const value of new Set([...Object.keys(table), ...observed])) {
      push(table[value] ?? {}, axis, value)
    }
    return { drafts, released, rejected }
  }

  if (entry.keys !== undefined || entry.ids !== undefined) {
    rejected.push({ cell: slot, slot, reason: 'bad_payload', detail: `keys/ids are meaningless on a ${kind} slot` })
    return { drafts, released, rejected }
  }
  push(entry, undefined, undefined)
  return { drafts, released, rejected }
}

/** Result of resolving rule 6 for one cell. */
type ChildResolution =
  | { ok: true; children: ChildrenTable; inherited: string[]; notes: string[] }
  | { ok: false; detail: string }

/**
 * The child slots a takeover of `slot` becomes responsible for: everything the
 * live occupants declared, plus everything the pinned contract says they
 * declare (the pin covers the load-order case where the official declarer has
 * not applied yet).
 *
 * One source for rules 6 and 7 on purpose: rule 6 must declare exactly the set
 * rule 7 demands be native, or the two rules could disagree about what a
 * "child" is.
 * @param slot - slot being taken over.
 * @param env - live ledger view.
 * @returns child name → the spec as found on the **live** ledger, or undefined
 * when only the pin knows the name (nobody declared it yet).
 */
export function declaredChildrenOf(slot: string, env: SlotEnvironment): Map<string, SlotSpecLike | undefined> {
  const children = new Map<string, SlotSpecLike | undefined>()
  for (const name of env.pinned(slot)?.childNames ?? []) children.set(name, undefined)
  for (const entry of env.entries(slot)) {
    for (const [child, spec] of Object.entries(entry.children ?? {})) children.set(child, spec)
  }
  return children
}

/**
 * Rule 6 — "declaring is claiming". Winning a slot that declares child slots
 * obliges us to account for **every** child; missing one rejects the whole row
 * with no partial application.
 *
 * Upstream constraint that shapes this: a slot has exactly ONE declarer
 * (`SlotCore.register` throws `slot "X" is already declared`), and the
 * declaration is independent of priority — the shadowed official entry stays
 * registered, so its declarations stay alive. Re-declaring what it already
 * declared would throw, so such children are *inherited* rather than
 * re-declared. Children nobody declared yet are declared by us, verbatim from
 * the pinned contract.
 * @param slot - slot being taken over.
 * @param mode - resolved mode of the cell.
 * @param env - live ledger view.
 * @returns the children table to register with, or a rejection detail.
 */
export function resolveChildren(slot: string, mode: Exclude<SlotMode, 'web'>, env: SlotEnvironment): ChildResolution {
  // A mirrored entry never wins the cell, so it never renders children and
  // must not claim their declarations.
  if (mode === 'mirrored') return { ok: true, children: {}, inherited: [], notes: [] }

  const pinned = env.pinned(slot)
  const declared = declaredChildrenOf(slot, env)
  if (declared.size === 0) return { ok: true, children: {}, inherited: [], notes: [] }

  const children: ChildrenTable = {}
  const inherited: string[] = []
  const notes: string[] = []
  const missing: string[] = []

  for (const [child, runtimeSpec] of declared) {
    const pinnedSpec = pinned?.childSpecs[child]
    if (runtimeSpec !== undefined && pinnedSpec !== undefined
      && (runtimeSpec.kind !== pinnedSpec.kind || runtimeSpec.scope !== pinnedSpec.scope)) {
      // Contract drift: the live declaration is not the one we pinned. Fail
      // loud instead of declaring something else verbatim (ARCHITECTURE.md §7).
      return {
        ok: false,
        detail: `child "${child}" drifted from the pinned contract `
          + `(pinned ${pinnedSpec.kind}/${pinnedSpec.scope}, live ${runtimeSpec.kind}/${runtimeSpec.scope})`,
      }
    }
    if (env.spec(child) !== undefined) {
      // Already declared (normally by the very entry we are shadowing). One
      // declarer per slot upstream, so we inherit rather than re-declare.
      inherited.push(child)
      continue
    }
    const spec = runtimeSpec ?? pinnedSpec
    if (spec === undefined) {
      missing.push(child)
      continue
    }
    children[child] = spec
  }

  if (missing.length > 0) {
    return {
      ok: false,
      detail: `cannot declare child slot(s) ${missing.join(', ')} verbatim: no live declaration and no pinned spec`,
    }
  }
  if (inherited.length > 0) {
    notes.push(
      `${slot}: inherited child declaration(s) ${inherited.join(', ')} from the shadowed occupant `
      + '(upstream allows exactly one declarer per slot)',
    )
  }
  return { ok: true, children, inherited, notes }
}

/** Result of resolving rule 7 for one cell. */
type TakeoverResolution =
  | { ok: true; notes: string[] }
  | { ok: false; detail: string }

/** How much of a slot one manifest row hands to Studio. */
export type RowOwnership = 'unlisted' | 'owned' | 'shared'

/**
 * Does a manifest row hand **every** cell of its slot to Studio?
 *
 * A row only counts as `owned` when its own mode is an owning mode AND no
 * `keys` / `ids` override sends a cell back to `web` / `mirrored` (rule 5 lets
 * them): a single official cell surviving inside a native parent is exactly the
 * hole rule 7 exists to prevent.
 * @param entry - the row, or undefined when the slot is unlisted (= web, rule 1).
 * @returns `unlisted` | `owned` | `shared`.
 */
export function rowOwnership(entry: SlotEntry | undefined): RowOwnership {
  if (entry === undefined) return 'unlisted'
  const parentMode: SlotMode = entry.mode ?? 'web'
  const overrides = [...Object.values(entry.keys ?? {}), ...Object.values(entry.ids ?? {})]
  const modes: SlotMode[] = [parentMode, ...overrides.map(self => self.mode ?? parentMode)]
  return modes.every(mode => OWNING_MODES.includes(mode)) ? 'owned' : 'shared'
}

/**
 * Ledger evidence that Studio already holds a slot: an entry stamped
 * {@link REGISTRANT} at a priority that is not the inert mirrored one.
 *
 * This is deliberately weaker than the manifest proof — it exists so a cell
 * taken over by an earlier `surface/configure` (or by a Studio plugin that
 * registered natively, outside any manifest) can still certify its parent.
 * @param slot - child slot to check.
 * @param env - live ledger view.
 * @returns whether Studio owns an entry on that slot.
 */
function ledgerOwned(slot: string, env: SlotEnvironment): boolean {
  return env.entries(slot).some(entry =>
    entry.registrant === REGISTRANT && (entry.options.priority ?? 0) !== MIRRORED_PRIORITY)
}

/**
 * Rule 7, recursive half: is `slot` (a child of something we are taking over)
 * itself fully Studio-owned, all the way down?
 * @param slot - child slot under scrutiny.
 * @param manifest - the whole manifest (rule 7 is a graph rule, not a row rule).
 * @param env - live ledger view.
 * @param trail - path from the slot that triggered the check, for diagnostics
 * and as a cycle guard.
 * @returns ok plus notes, or the rejection detail.
 */
function takenOver(slot: string, manifest: Manifest, env: SlotEnvironment, trail: string[]): TakeoverResolution {
  const ownership = rowOwnership(manifest[slot])
  // The manifest proof is transitive: a native child whose own children are
  // still web cannot certify its parent, because it will be rejected too.
  if (ownership === 'owned') return childrenTakenOver(slot, manifest, env, trail)
  if (ledgerOwned(slot, env)) {
    return {
      ok: true,
      notes: [`${trail.join(' → ')}: accepted on ledger evidence (an entry of "${REGISTRANT}" already owns "${slot}")`],
    }
  }
  const because = ownership === 'unlisted'
    ? 'unlisted, so rule 1 leaves it to the official Web UI'
    : `configured with at least one non-native cell (${SLOT_MODES.filter(mode => !OWNING_MODES.includes(mode)).join('/')})`
  return {
    ok: false,
    detail: `child slot "${slot}" (${trail.join(' → ')}) is ${because}; `
      + 'a native parent never mounts its official children, so take the child over first (rule 7 is bottom-up)',
  }
}

/**
 * Rule 7, iterating half: every declared child of `slot` must be Studio-owned.
 * @param slot - slot being taken over.
 * @param manifest - the whole manifest.
 * @param env - live ledger view.
 * @param trail - path walked so far (cycle guard).
 * @returns ok plus notes, or the rejection detail.
 */
function childrenTakenOver(slot: string, manifest: Manifest, env: SlotEnvironment, trail: string[]): TakeoverResolution {
  const notes: string[] = []
  for (const child of declaredChildrenOf(slot, env).keys()) {
    // Upstream allows exactly one declarer per slot, so a declaration cycle is
    // not constructible; guarding anyway beats hanging on malformed input.
    if (trail.includes(child)) continue
    const owned = takenOver(child, manifest, env, [...trail, child])
    if (!owned.ok) return owned
    notes.push(...owned.notes)
  }
  return { ok: true, notes }
}

/**
 * Rule 7 — "takeover is bottom-up" (G-2, surface-manifest.md §4).
 *
 * A `native` / `retired` parent wins the cell and renders one native view in
 * place of the official React subtree. The child slots that subtree declared
 * stay *declared* (rule 6 keeps the declarations alive) but nothing ever
 * renders them: `renderSlot` is only called by the official component that no
 * longer mounts. Accepting such a row would therefore delete official UI
 * silently — the exact failure mode ARCHITECTURE.md §7 forbids.
 *
 * So a parent may only be taken over when every declared child is already
 * Studio's: native/retired in this same manifest (checked recursively, leaves
 * first) or held by {@link REGISTRANT} on the live ledger. `mirrored` is exempt
 * — it never wins a cell, so it hides nothing.
 * @param slot - slot being taken over.
 * @param mode - resolved mode of the cell.
 * @param manifest - the whole manifest, since ownership of a child lives in
 * another row.
 * @param env - live ledger view.
 * @returns ok plus diagnostics, or the rejection detail naming the child that blocks it.
 */
export function resolveChildTakeover(
  slot: string,
  mode: Exclude<SlotMode, 'web'>,
  manifest: Manifest,
  env: SlotEnvironment,
): TakeoverResolution {
  if (mode === 'mirrored') return { ok: true, notes: [] }
  return childrenTakenOver(slot, manifest, env, [slot])
}

/**
 * Plan a manifest: pure, so every rule is testable without a live registry.
 * @param manifest - parsed manifest.
 * @param env - live ledger view.
 * @returns the plan.
 */
export function planManifest(manifest: Manifest, env: SlotEnvironment): ManifestPlan {
  const registrations: CellRegistration[] = []
  const released: string[] = []
  const rejected: Rejection[] = []
  const notes: string[] = []

  // Rule 1: only listed slots are considered. An unlisted slot (including one
  // upstream added yesterday) keeps its official occupant untouched.
  for (const [slot, entry] of Object.entries(manifest)) {
    const live = env.spec(slot)
    const pinned = env.pinned(slot)
    // The pin covers the load-order case: the host may configure us before the
    // declaring official plugin applied, and registration is deferred through
    // `ctx.slots.inject` anyway.
    const spec = live ?? pinned?.spec
    if (spec === undefined) {
      rejected.push({
        cell: slot,
        slot,
        reason: 'slot_not_declared',
        detail: `slot "${slot}" is neither declared in this build nor pinned by a contract module`,
      })
      continue
    }
    if (live !== undefined && pinned !== undefined
      && (live.kind !== pinned.spec.kind || live.scope !== pinned.spec.scope)) {
      rejected.push({
        cell: slot,
        slot,
        reason: 'slot_not_declared',
        detail: `slot "${slot}" drifted from the pinned contract `
          + `(pinned ${pinned.spec.kind}/${pinned.spec.scope}, live ${live.kind}/${live.scope})`,
      })
      continue
    }
    if (live === undefined) {
      notes.push(`${slot}: not declared yet; registration is deferred until the declaring entry loads`)
    }
    if (spec.kind === 'chain') {
      // A chain entry needs a pure `select` routing function; the manifest has
      // no way to express one and the generic proxy has no basis to route.
      rejected.push({
        cell: slot,
        slot,
        reason: 'bad_payload',
        detail: 'chain slots need a registration-time selector; the generic proxy cannot take over a chain',
      })
      continue
    }

    const expansion = expandCells(slot, entry, spec.kind, env)
    released.push(...expansion.released)
    rejected.push(...expansion.rejected)

    for (const draft of expansion.drafts) {
      const occupied = env.entries(slot).some((candidate) => {
        const sameCell = spec.kind === 'keyed'
          ? candidate.options.key === draft.key
          : spec.kind === 'list' ? candidate.options.id === draft.id : true
        return sameCell && (candidate.options.priority ?? 0) === draft.priority
      })
      if (occupied) {
        // §1.5: priority_conflict must fail loud. Moving ourselves to another
        // priority would silently change who renders.
        rejected.push({
          cell: draft.cell,
          slot,
          reason: 'priority_conflict',
          detail: `priority ${draft.priority} on "${draft.cell}" is already occupied; a human must decide, we do not relocate`,
        })
        continue
      }

      const childResolution = resolveChildren(slot, draft.mode, env)
      if (!childResolution.ok) {
        rejected.push({ cell: draft.cell, slot, reason: 'slot_not_declared', detail: childResolution.detail })
        continue
      }
      // Rule 7 comes after rule 6 on purpose: rule 6 settles WHICH children the
      // takeover owns, rule 7 checks they are all ours before the parent goes
      // native. The manifest asked for something inconsistent, hence bad_payload.
      const takeover = resolveChildTakeover(slot, draft.mode, manifest, env)
      if (!takeover.ok) {
        rejected.push({ cell: draft.cell, slot, reason: 'bad_payload', detail: takeover.detail })
        continue
      }
      notes.push(...childResolution.notes, ...takeover.notes)
      if (draft.mode === 'mirrored') {
        // Upstream renders only the winning entry of a cell
        // (`SlotCore.entriesOfSlot`), so a +1 passenger never mounts and no
        // slot/mount will follow. Recorded here rather than silently applied.
        notes.push(
          `${draft.cell}: mirrored registration is inert under upstream shadowing `
          + '(only the cell winner renders — see the W1 report)',
        )
      }
      registrations.push({
        cell: draft.cell,
        slot,
        mode: draft.mode,
        placement: draft.placement,
        priority: draft.priority,
        scope: spec.scope,
        kind: spec.kind,
        ...(draft.key === undefined ? {} : { key: draft.key }),
        ...(draft.id === undefined ? {} : { id: draft.id }),
        children: childResolution.children,
        inheritedChildren: childResolution.inherited,
      })
    }
  }

  return { registrations, released, rejected, notes }
}

/** Stateful manifest application, including hot reconfiguration (§5). */
export interface ManifestController {
  /**
   * Apply a full manifest (`surface/configure`).
   * @param raw - untrusted `manifest` payload member.
   */
  configure(raw: unknown): ConfigureResult
  /**
   * Apply a patch (`surface/reconfigure`): merges onto the retained manifest,
   * then re-applies. Registration is a reversible `ctx.effect`, so this is a
   * dispose + rebuild — no page reload, no runtime restart.
   * @param raw - untrusted `patch` payload member.
   */
  reconfigure(raw: unknown): ConfigureResult
  /** Currently installed cells. */
  readonly active: readonly string[]
  /** The manifest last accepted (after merges), for diagnostics. */
  readonly current: Manifest
  /** Dispose every registration (protocol mismatch → pure Web fallback, §4). */
  disposeAll(): void
}

/**
 * Create the manifest controller.
 * @param runtime - registration seam + ledger view.
 * @returns the controller.
 */
export function createManifestController(runtime: ManifestRuntime): ManifestController {
  const installed = new Map<string, () => void>()
  let retained: Manifest = {}
  const log = runtime.log ?? ((): void => {})

  const release = (cell: string): void => {
    const dispose = installed.get(cell)
    if (dispose === undefined) return
    installed.delete(cell)
    dispose()
    log(`released ${cell}`)
  }

  const apply = (manifest: Manifest, rejectedFromParse: Rejection[]): ConfigureResult => {
    const plan = planManifest(manifest, runtime.env)
    const applied: string[] = []
    const rejected = [...rejectedFromParse, ...plan.rejected]

    // Rule 2 first: a cell going back to web must free the cell before anything
    // else re-registers, otherwise a hot switch would clash with itself.
    for (const cell of plan.released) release(cell)
    for (const rejection of plan.rejected) release(rejection.cell)

    for (const registration of plan.registrations) {
      release(registration.cell)
      try {
        installed.set(registration.cell, runtime.install(registration))
        applied.push(registration.cell)
      } catch (error) {
        installed.delete(registration.cell)
        rejected.push({
          cell: registration.cell,
          slot: registration.slot,
          reason: classifyRegisterFailure(error),
          detail: error instanceof Error ? error.message : String(error),
        })
      }
    }

    // Cells that vanished from a full manifest fall back to rule 1 (= web).
    for (const cell of [...installed.keys()]) {
      const stillPlanned = plan.registrations.some(registration => registration.cell === cell)
      if (!stillPlanned) release(cell)
    }

    return { applied, rejected, notes: plan.notes }
  }

  return {
    get active() { return [...installed.keys()] },
    get current() { return retained },

    configure(raw) {
      const { manifest, rejected } = parseManifest(raw)
      retained = manifest
      return apply(manifest, rejected)
    },

    reconfigure(raw) {
      const { manifest, rejected } = parseManifest(raw)
      // A patch row replaces the whole row for that slot — the same semantics
      // the official config patcher uses (surface-manifest.md §6).
      retained = { ...retained, ...manifest }
      return apply(retained, rejected)
    },

    disposeAll() {
      for (const cell of [...installed.keys()]) release(cell)
    },
  }
}

/**
 * Map an upstream `register` failure onto the closed error set (§1.5).
 * @param error - what `ctx.slots.register` threw.
 * @returns the wire code.
 */
export function classifyRegisterFailure(error: unknown): BridgeErrorCode {
  const message = error instanceof Error ? error.message : String(error)
  if (/already has (a registration|an entry)/.test(message)) return 'priority_conflict'
  if (/is already declared/.test(message)) return 'slot_not_declared'
  if (/is not declared/.test(message)) return 'slot_not_declared'
  return 'internal'
}
