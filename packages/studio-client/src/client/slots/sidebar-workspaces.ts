/**
 * W1 target slot — `sidebar.workspaces` (playbook §① "立契约").
 *
 * Everything here is transcribed from upstream and pinned so that a change on
 * the other side is a **compile error in this file**, not a blank column at
 * runtime:
 *
 * - declaration: `packages/client/ui-sidebar/src/client/index.ts` declares the
 *   slot in its `sidebar` registration's `children` table
 *   (`{ kind: 'single', scope: 'root' }`), official occupant = ui-workspace's
 *   `WorkspaceBrowser` at the default priority 0.
 * - owner share: `SidebarSectionOwnerProps` in
 *   `packages/client/ui-sidebar/src/client/contract/slots.ts` — `wide`
 *   (orchestration) + `expandSidebar` (an action, so it rides `slot/invoke`).
 * - child slot: the occupant declares `sidebar.workspaces.directoryFlow`
 *   (`{ kind: 'single', scope: 'root' }`) in
 *   `packages/client/ui-workspace/src/client/index.ts`. That is the child rule
 *   6 is about.
 *
 * Upstream reference: `deepseek-harness` @ 0.1.0-rc.5.
 */

import type { SidebarSectionOwnerProps } from '@deepseek-ai/dsh-client-ui-sidebar/client'
import type { DirectoryFlowOwnerProps } from '@deepseek-ai/dsh-client-ui-workspace/client'
import type { SlotSpecLike } from '@deepseek-ai/dsh-client-ui-slots'
import type { PinnedSlotContract } from '../manifest.ts'

/** Upstream version this pin was transcribed from. */
export const UPSTREAM_VERSION = '0.1.0-rc.5'

/** Slot name. */
export const SIDEBAR_WORKSPACES = 'sidebar.workspaces'

/** Child slot the official occupant declares. */
export const SIDEBAR_WORKSPACES_DIRECTORY_FLOW = 'sidebar.workspaces.directoryFlow'

/** Owner share as transcribed from upstream (the hand-off surface of this slot). */
export interface SidebarWorkspacesOwnerProps {
  /** Shell fold state: wide renders the full browser, rail the icon column. */
  wide: boolean
  /** Rail icons request expansion (an action — never serialized). */
  expandSidebar: () => void
}

/** Owner share of the child directory-flow hole, as transcribed from upstream. */
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

/** Pinned contract consumed by manifest rule 6. */
export const SIDEBAR_WORKSPACES_CONTRACT: PinnedSlotContract = {
  slot: SIDEBAR_WORKSPACES,
  spec: { kind: 'single', scope: 'root' } satisfies SlotSpecLike,
  childNames: [SIDEBAR_WORKSPACES_DIRECTORY_FLOW],
  childSpecs: {
    [SIDEBAR_WORKSPACES_DIRECTORY_FLOW]: { kind: 'single', scope: 'root' },
  },
}

/** Structural equality helper for the drift assertions below. */
type Equals<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false

/** Compile-time assertion carrier. */
type Expect<T extends true> = T

/**
 * Drift guard: our pin must be structurally identical to the upstream
 * declaration. Upstream adding, removing, or retyping a member breaks the
 * build here — the free insurance ARCHITECTURE.md §7 promises.
 */
export type AssertOwnerSharePinned = Expect<Equals<SidebarWorkspacesOwnerProps, SidebarSectionOwnerProps>>

/** Same guard for the child hole's owner share. */
export type AssertDirectoryFlowSharePinned =
  Expect<Equals<SidebarWorkspacesDirectoryFlowOwnerProps, DirectoryFlowOwnerProps>>
