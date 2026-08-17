/**
 * The one and only place `studio-client` touches the upstream client packages.
 *
 * WHY THIS MODULE EXISTS
 * ----------------------
 * Studio drives registration from a **runtime manifest**
 * (surface-manifest.md), while the official `ctx.slots` face is statically
 * keyed on `SlotMap`: `register` is a pair of overloads generic in
 * `K extends keyof SlotMap & string`, and `entries` / `spec` / `inject` /
 * `subscribe` all take that same narrowed key. A slot name that only exists as
 * a string at runtime cannot be expressed on that face — upstream hits the
 * same wall itself and answers it with `SlotCore.specDynamic`, "the dynamic-key
 * escape hatch for renderers resolving keys they only hold as strings".
 *
 * This module is Studio's version of that escape hatch, and it is deliberately
 * the **only** one: every other file imports `DynamicSlots` from here and never
 * `SlotRegistry`, so there is exactly one `as unknown as` in the package and it
 * has a test-visible name ({@link dynamicSlots}).
 *
 * WHAT REPLACES THE STATIC CHECKING WE GIVE UP
 * --------------------------------------------
 * Three layers, all compile-time, none of them a comment:
 *
 *  1. **Member-level drift guards** (bottom of this file). `DynamicSlots` may
 *     not name a member `SlotRegistry` does not have, and every erased member's
 *     non-key types (`StoredEntry`, `LiveSlotNode`, the injection-effect shape,
 *     the entry-error callback, the disposer) must be *identical* to upstream's,
 *     not merely compatible. An upstream rename or signature change is a
 *     compile error in this file.
 *  2. **Typed registration probes** (`slots/sidebar-workspaces.ts`). For every
 *     slot Studio is allowed to take over, a never-called function performs a
 *     real, fully typed `slots.register(...)` with the very options the
 *     manifest planner mints. That proves the slot key exists in the live
 *     `SlotMap` and that `priority` / `registrant` / `children` are legal there.
 *  3. **Pinned contract equality** (same file). The pinned owner share and
 *     child specs are compared to the real `SlotMap` entries with an exact
 *     `Equals`, so a widened or renamed upstream prop breaks the build.
 *
 * Nothing here is transcribed from upstream source any more: every type below
 * is either imported from the published package or derived from it.
 */

import type { Disposable } from '@deepseek-ai/cordis'
import type {
  LiveSlotNode, SlotEntryDef, SlotKind, SlotMap, SlotScope, SlotSpec, StoredEntry,
} from '@deepseek-ai/dsh-client-ui-slots'
import type { ClientContext, SlotRegistry } from '@deepseek-ai/dsh-client-runtime/client'

export type { LiveSlotNode, SlotKind, SlotScope, StoredEntry }

/**
 * A slot spec with its key erased — literally `SlotSpec<E>` instantiated at the
 * base entry definition, which is what upstream's own `specDynamic` returns.
 * Resolves to `{ kind: SlotKind; scope: SlotScope; inject?: object }`.
 */
export type SlotSpecLike = SlotSpec<SlotEntryDef>

/** A `children` declaration table with its keys erased (upstream `ChildrenDecl`). */
export type ChildrenTable = Record<string, SlotSpecLike>

/**
 * Registration options for a dynamically keyed entry: the members Studio sets,
 * with `name` widened to `string`.
 *
 * Members upstream also accepts but Studio never sets (`store`, `select`,
 * `order`, `label`, `locale`, `inject`) are omitted rather than typed loosely —
 * a manifest cannot express any of them, so they must not be reachable.
 */
export interface DynamicRegisterOptions {
  /** Target slot the entry contributes into. */
  name: string
  /** Child slots this entry declares (declaring is claiming). */
  children?: ChildrenTable
  /** Cell key of a `keyed` slot. */
  key?: string
  /** Cell id of a `list` slot. */
  id?: string
  /** Cell shadowing rank: ascending, default 0, lowest renders. */
  priority?: number
  /** Diagnostics label; the service layer stamps the fiber name when absent. */
  registrant?: string
}

/**
 * One synchronous effect installed while an injected declaration is live —
 * upstream's `SlotInjectionEffect`, which is not exported (it is a private
 * alias inside `runtime/client/slots.ts`) and is therefore restated here and
 * pinned by {@link AssertInjectFace}.
 */
export type SlotInjectionEffect = (() => void) | Iterable<() => void, void, void>

/** Entry-error observer, exactly as `SlotRegistry.onEntryError` takes it. */
export type EntryErrorObserver = (
  key: string,
  entry: StoredEntry,
  error: unknown,
  info: { abdicated: boolean },
) => void

/**
 * `ctx.slots` with every SlotMap key widened to `string`. Same members, same
 * return types, same runtime object — only the key typing differs.
 */
export interface DynamicSlots {
  /** Contribute a component to a declared slot; the disposer removes it. */
  register(options: DynamicRegisterOptions, component: unknown): () => void
  /** Install an effect for each declaration lifetime of a slot. */
  inject(key: string, callback: () => SlotInjectionEffect): () => void
  /** Raw ledger of a slot: every entry at every priority. */
  entries(key: string): readonly StoredEntry[]
  /** Shadowing winners of a slot: the entry that renders in each cell. */
  entriesOfSlot(key: string): readonly StoredEntry[]
  /** Declared spec of a slot, undefined while undeclared. */
  spec(key: string): SlotSpecLike | undefined
  /** JSON-safe declaration tree. */
  snapshot(root?: string): LiveSlotNode[]
  /** Registration changes of a slot (microtask-batched). */
  subscribe(key: string, fn: () => void): () => void
  /** Entry boundary crashes, abdicating or not. */
  onEntryError(fn: EntryErrorObserver): () => void
}

/**
 * The context face Studio's client half needs.
 *
 * Stated structurally rather than as `ClientContext`, for a reason that is not
 * cosmetic: upstream's `ClientContext` *is* the whole Cordis `Context` with
 * `slots`, `sessions`, `workspaces`, `conversationEvents` and
 * `conversationViews` merged onto it, so depending on it would (a) let this
 * package reach services ARCHITECTURE.md §3 says it must not touch, and (b)
 * make the test doubles unbuildable — a fake would have to implement the entire
 * service surface to satisfy one call to `ctx.effect`.
 *
 * {@link AssertClientContextFits} proves the real context still satisfies it.
 */
export interface StudioContext {
  /**
   * Register a reversible side effect owned by the caller's fiber. Only the
   * synchronous shape is declared: the client half installs slot
   * registrations and receivers, never an async resource (that is the host
   * half's job, and it uses the real `Context` directly).
   */
  effect(execute: () => Disposable<void>, label?: string): Disposable<Promise<void>>
  /** The slot seam, dynamically keyed (see {@link dynamicSlots}). */
  slots: DynamicSlots
}

/**
 * Erase the statically keyed slot face onto {@link DynamicSlots}.
 *
 * This is the single type assertion in the package. It is sound because the
 * erasure is *only* on key types: the guards below pin every other type in
 * every erased signature to upstream's, so the cast cannot silently start
 * lying about a return value or a callback shape.
 * @param slots - the real `ctx.slots` service.
 * @returns the same object, dynamically keyed.
 */
export function dynamicSlots(slots: SlotRegistry): DynamicSlots {
  return slots as unknown as DynamicSlots
}

/**
 * Adapt a real client context onto {@link StudioContext}.
 * @param ctx - the official client root context.
 * @returns the narrowed Studio face over the same context.
 */
export function studioContext(ctx: ClientContext): StudioContext {
  return { effect: (execute, label) => ctx.effect(execute, label), slots: dynamicSlots(ctx.slots) }
}

// ── drift guards ────────────────────────────────────────────────────────────
//
// `Equals` (not `extends`) on purpose: a widened upstream signature would still
// satisfy `extends` while quietly changing what the erasure means.

/** Structural identity, the standard invariant-position trick. */
type Equals<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false

/** Compile-time assertion carrier. */
type Expect<T extends true> = T

/** Every SlotMap key, as the official face narrows its arguments to. */
type SlotKey = keyof SlotMap & string

/**
 * No invented members: `DynamicSlots` may only erase things `SlotRegistry`
 * actually has. An upstream rename (or a member we hallucinated) lands here.
 */
export type AssertNoInventedMembers = Expect<Equals<Exclude<keyof DynamicSlots, keyof SlotRegistry>, never>>

/** The disposer contract of a registration is upstream's, not a wish. */
export type AssertRegisterDisposer =
  Expect<Equals<ReturnType<SlotRegistry['register']>, ReturnType<DynamicSlots['register']>>>

/** `inject`'s effect shape and disposer, restated above, pinned here. */
export type AssertInjectFace =
  Expect<Equals<SlotRegistry['inject'], (key: SlotKey, callback: () => SlotInjectionEffect) => () => void>>

/** The raw ledger view really is `readonly StoredEntry[]`. */
export type AssertEntriesFace =
  Expect<Equals<SlotRegistry['entries'], (key: SlotKey) => readonly StoredEntry[]>>

/** …and so is the shadowing-winners projection. */
export type AssertEntriesOfSlotFace =
  Expect<Equals<SlotRegistry['entriesOfSlot'], (key: SlotKey) => readonly StoredEntry[]>>

/** `snapshot` takes a plain string upstream too, so it is erased identically. */
export type AssertSnapshotFace = Expect<Equals<SlotRegistry['snapshot'], DynamicSlots['snapshot']>>

/** `subscribe`'s callback and disposer. */
export type AssertSubscribeFace =
  Expect<Equals<SlotRegistry['subscribe'], (key: SlotKey, fn: () => void) => () => void>>

/** The entry-error observer, including the `abdicated` flag `slot/error` forwards. */
export type AssertOnEntryErrorFace =
  Expect<Equals<SlotRegistry['onEntryError'], DynamicSlots['onEntryError']>>

/**
 * Every slot declared anywhere in this build has a spec our wide spec can hold
 * — the property that makes {@link SlotSpecLike} the right erasure. Written as a
 * mapped union over the live `SlotMap` rather than `ReturnType<spec>`, because
 * `ReturnType` of a *generic* signature collapses to `any` and would assert
 * nothing.
 */
type SpecOfEverySlot = { [K in SlotKey]: SlotSpec<SlotMap[K]> }[SlotKey]

/** @see SpecOfEverySlot */
export type AssertSpecErasure = Expect<[SpecOfEverySlot] extends [SlotSpecLike] ? true : false>

/**
 * The real client context satisfies the narrow face Studio asks for. `slots` is
 * excluded because that member is exactly what {@link dynamicSlots} erases; the
 * guards above cover it member by member.
 */
export type AssertClientContextFits = Expect<ClientContext extends Omit<StudioContext, 'slots'> ? true : false>
