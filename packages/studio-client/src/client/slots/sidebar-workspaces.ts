/**
 * W1 target slot — `sidebar.workspaces` (playbook §① "立契约").
 *
 * The pins below are no longer transcriptions: every one of them is checked
 * against the **installed** upstream packages, so a change on the other side is
 * a compile error in this file rather than a blank column at runtime
 * (ARCHITECTURE.md §7).
 *
 * - declaration: `@deepseek-ai/dsh-client-ui-sidebar/client` merges
 *   `sidebar.workspaces` into `SlotMap` as `{ kind: 'single', scope: 'root',
 *   owner: SidebarSectionOwnerProps }`; the official occupant is
 *   ui-workspace's `WorkspaceBrowser` at the default priority 0.
 * - owner share: `SidebarSectionOwnerProps` — `wide` (orchestration) +
 *   `expandSidebar` (an action, so it rides `slot/invoke`).
 * - child slot: the occupant declares `sidebar.workspaces.directoryFlow`
 *   (`@deepseek-ai/dsh-client-ui-workspace/client`). That is the child rule 6
 *   is about.
 *
 * Upstream reference: `deepseek-harness` @ 0.1.0-rc.6.
 */

import type { SidebarSectionOwnerProps } from '@deepseek-ai/dsh-client-ui-sidebar/client'
import type { DirectoryFlowOwnerProps } from '@deepseek-ai/dsh-client-ui-workspace/client'
import type { SlotMap, SlotSpec } from '@deepseek-ai/dsh-client-ui-slots'
import type { SlotRegistry } from '@deepseek-ai/dsh-client-runtime/client'
import type { PinnedSlotContract } from '../manifest.ts'
import { DEFAULT_SHADOW_PRIORITY, MIRRORED_PRIORITY, REGISTRANT } from '../manifest.ts'
import type { nativeSlot } from '../native-slot.tsx'
import type { SlotSpecLike } from '../upstream.ts'

/** The generic proxy's type — what the probes below prove is registrable here. */
type Proxy = ReturnType<typeof nativeSlot>

/** Upstream version this contract was validated against. */
export const UPSTREAM_VERSION = '0.1.0-rc.6'

/** Slot name. */
export const SIDEBAR_WORKSPACES = 'sidebar.workspaces'

/** Child slot the official occupant declares. */
export const SIDEBAR_WORKSPACES_DIRECTORY_FLOW = 'sidebar.workspaces.directoryFlow'

/**
 * Owner share as pinned by Studio (the hand-off surface of this slot).
 * {@link AssertOwnerSharePinned} holds it identical to upstream's.
 */
export interface SidebarWorkspacesOwnerProps {
  /** Shell fold state: wide renders the full browser, rail the icon column. */
  wide: boolean
  /** Rail icons request expansion (an action — never serialized). */
  expandSidebar: () => void
}

/** Owner share of the child directory-flow hole, as pinned by Studio. */
export interface SidebarWorkspacesDirectoryFlowOwnerProps {
  open: boolean
  busy: boolean
  onPicked: (path: string) => void
  onCancel: () => void
  onError: (message: string) => void
}

/** Members of the owner share that may cross the control channel (ADR-0002). */
export const SIDEBAR_WORKSPACES_ORCHESTRATION_PROPS = ['wide'] as const

/** Members of the owner share the native view calls back by name (`slot/invoke`). */
export const SIDEBAR_WORKSPACES_ACTIONS = ['expandSidebar'] as const

/**
 * Spec of the child hole, written once and consumed both by the pinned contract
 * and by the typed registration probe — so the value the manifest would really
 * declare is the value the compiler checks.
 */
const DIRECTORY_FLOW_SPEC = { kind: 'single', scope: 'root' } as const

/** Spec of the slot itself, pinned so a `configure` arriving before the
 * declaring plugin loaded can still be planned (rule 1's load-order case). */
const SIDEBAR_WORKSPACES_SPEC = { kind: 'single', scope: 'root' } as const

/** Pinned contract consumed by manifest rules 6 and 7. */
export const SIDEBAR_WORKSPACES_CONTRACT: PinnedSlotContract = {
  slot: SIDEBAR_WORKSPACES,
  spec: SIDEBAR_WORKSPACES_SPEC satisfies SlotSpecLike,
  childNames: [SIDEBAR_WORKSPACES_DIRECTORY_FLOW],
  childSpecs: {
    [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: DIRECTORY_FLOW_SPEC,
  },
}

/**
 * Pinned contract of the child hole itself.
 *
 * It exists because rule 7 makes W1 a **two-row** manifest: the section cannot
 * go native while its directory-flow hole stays official, so the hole gets a row
 * of its own — and a row can only be planned for a slot that is declared or
 * pinned. Upstream declares this hole from the occupant's `children` table, i.e.
 * only once ui-workspace has applied, so without this pin a `surface/configure`
 * arriving early would reject the child and (by rule 7) the parent with it.
 */
export const SIDEBAR_WORKSPACES_DIRECTORY_FLOW_CONTRACT: PinnedSlotContract = {
  slot: SIDEBAR_WORKSPACES_DIRECTORY_FLOW,
  spec: DIRECTORY_FLOW_SPEC satisfies SlotSpecLike,
  // The hole declares nothing itself: it is a leaf, which is what makes it the
  // slot rule 7 lets us take over first.
  childNames: [],
  childSpecs: {},
}

// ── typed registration probes ───────────────────────────────────────────────
//
// Never called. Their only job is to make `tsc` run the **real**, fully typed
// `SlotRegistry.register` overload resolution against the exact options the
// manifest planner mints for this slot. That is what recovers the static
// checking `upstream.ts` erases: if upstream renames the slot, changes its
// kind, drops `priority` / `registrant`, or moves the child hole, one of these
// stops compiling.
//
// The component is the REAL proxy type (`ReturnType<typeof nativeSlot>`), not a
// stand-in: since the proxy takes `Record<string, unknown>` it must satisfy
// upstream's composed-props constraint for this slot, and it satisfies
// upstream's `RendersCheck` (declaring children obliges the component to accept
// `renderSlot`) through that same wide props type — which is why the child
// declaration below is legal at all.

/**
 * A `native` / `retired` takeover: shadow the official entry from below.
 * @param slots - the official registry (never invoked).
 * @param component - the generic proxy.
 * @returns the registration disposer.
 */
export function assertShadowingRegistrationTypechecks(slots: SlotRegistry, component: Proxy): () => void {
  return slots.register({
    name: SIDEBAR_WORKSPACES,
    priority: DEFAULT_SHADOW_PRIORITY,
    registrant: REGISTRANT,
  }, component)
}

/**
 * A `mirrored` passenger: same cell, higher priority, never wins the render.
 * @param slots - the official registry (never invoked).
 * @param component - the generic proxy.
 * @returns the registration disposer.
 */
export function assertMirroredRegistrationTypechecks(slots: SlotRegistry, component: Proxy): () => void {
  return slots.register({
    name: SIDEBAR_WORKSPACES,
    priority: MIRRORED_PRIORITY,
    registrant: REGISTRANT,
  }, component)
}

/**
 * Rule 6's other branch: a takeover that has to declare the child hole itself
 * (the official occupant has not loaded, so nobody declared it yet). Proves the
 * child name is a real `SlotMap` key and the pinned spec is its exact spec.
 * @param slots - the official registry (never invoked).
 * @param component - the generic proxy.
 * @returns the registration disposer.
 */
export function assertChildDeclarationTypechecks(slots: SlotRegistry, component: Proxy): () => void {
  return slots.register({
    name: SIDEBAR_WORKSPACES,
    priority: DEFAULT_SHADOW_PRIORITY,
    registrant: REGISTRANT,
    children: { [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: DIRECTORY_FLOW_SPEC },
  }, component)
}

/**
 * Rule 7's leaf registration: the child hole taken over on its own, which is
 * what a bottom-up W1 manifest does before it touches the parent.
 * @param slots - the official registry (never invoked).
 * @param component - the generic proxy.
 * @returns the registration disposer.
 */
export function assertChildTakeoverRegistrationTypechecks(slots: SlotRegistry, component: Proxy): () => void {
  return slots.register({
    name: SIDEBAR_WORKSPACES_DIRECTORY_FLOW,
    priority: DEFAULT_SHADOW_PRIORITY,
    registrant: REGISTRANT,
  }, component)
}

// ── contract equality guards ────────────────────────────────────────────────

/** Structural equality helper for the drift assertions below. */
type Equals<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false

/** Compile-time assertion carrier. */
type Expect<T extends true> = T

/** Drops `readonly` so an `as const` pin can be compared to upstream's spec. */
type Mutable<T> = { -readonly [K in keyof T]: T[K] }

/**
 * Drift guard: our pin must be structurally identical to the upstream owner
 * share. Upstream adding, removing, or retyping a member breaks the build here
 * — the free insurance ARCHITECTURE.md §7 promises.
 */
export type AssertOwnerSharePinned = Expect<Equals<SidebarWorkspacesOwnerProps, SidebarSectionOwnerProps>>

/** Same guard for the child hole's owner share. */
export type AssertDirectoryFlowSharePinned =
  Expect<Equals<SidebarWorkspacesDirectoryFlowOwnerProps, DirectoryFlowOwnerProps>>

/**
 * The whole `SlotMap` entry, not just its owner share: `kind` and `scope` are
 * what the manifest planner branches on (rule 5 expands `keyed` / `list` cells,
 * a `chain` is refused outright), so a kind flip upstream must be a compile
 * error and not a silently mis-planned manifest.
 */
export type AssertSlotDeclaration = Expect<Equals<
  SlotMap['sidebar.workspaces'],
  { kind: 'single'; scope: 'root'; owner: SidebarSectionOwnerProps }
>>

/** Same for the child hole. */
export type AssertChildSlotDeclaration = Expect<Equals<
  SlotMap['sidebar.workspaces.directoryFlow'],
  { kind: 'single'; scope: 'root'; owner: DirectoryFlowOwnerProps }
>>

/**
 * The pinned specs carry exactly the `kind` / `scope` upstream's own typing
 * demands. Compared on those two members only, because `SlotSpec` also carries
 * an `inject?: never` branch that a value literal cannot spell — while `kind`
 * and `scope` are precisely what the manifest planner branches on.
 */
export type AssertSlotSpecPinned = Expect<Equals<
  Mutable<typeof SIDEBAR_WORKSPACES_SPEC>,
  Pick<SlotSpec<SlotMap['sidebar.workspaces']>, 'kind' | 'scope'>
>>

/** @see AssertSlotSpecPinned */
export type AssertChildSpecPinned = Expect<Equals<
  Mutable<typeof DIRECTORY_FLOW_SPEC>,
  Pick<SlotSpec<SlotMap['sidebar.workspaces.directoryFlow']>, 'kind' | 'scope'>
>>
