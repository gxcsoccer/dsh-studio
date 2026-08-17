/**
 * Pinned slot contracts (playbook §①). One module per slot; this index is the
 * only place the manifest resolver looks up a pin, so adding a wave's slot is
 * one import plus one row — never a branch inside the proxy component.
 */

import type { PinnedSlotContract } from '../manifest.ts'
import { SIDEBAR_WORKSPACES, SIDEBAR_WORKSPACES_CONTRACT } from './sidebar-workspaces.ts'

/** All pinned contracts, keyed by slot name. */
export const PINNED_CONTRACTS: Readonly<Record<string, PinnedSlotContract>> = {
  [SIDEBAR_WORKSPACES]: SIDEBAR_WORKSPACES_CONTRACT,
}

/**
 * Look up the pinned contract of a slot.
 * @param slot - slot name.
 * @returns the contract, or undefined for a slot we have not pinned yet.
 */
export function pinnedContract(slot: string): PinnedSlotContract | undefined {
  return PINNED_CONTRACTS[slot]
}

export * from './sidebar-workspaces.ts'
