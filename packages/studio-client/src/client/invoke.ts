/**
 * `slot/invoke` — the callback table (reference/native-slot-proxy.md §2).
 *
 * The official injection faces hand components real functions
 * (`startSession`, `expandSidebar`, …). Functions cannot be serialized, so
 * `slot/mount` carries only their **names** and the native view calls them
 * back by name. Nothing but the action name and its arguments crosses the
 * bridge — the call transports an intent, never domain data (ADR-0002).
 *
 * Security boundary (bridge-contract.md §5, row `slot/invoke`): only instances
 * whose slot the manifest declared `native` / `retired` are invocable. A
 * `mirrored` instance is a passenger; letting the host drive its callbacks
 * would make the "陪跑" state observable to the user.
 */

import { bridgeError, type Bridge } from './bridge.ts'
import { expectString, jsonSafe, optionalArray, optionalString, type JsonValue } from './payload.ts'

/** One entry of an instance's injection face. */
export type SlotAction = (...args: readonly unknown[]) => unknown

/**
 * Props the framework itself installs. They are function-valued but are not
 * actions: `renderSlot` renders inside React, `use*` are selector hooks that
 * throw outside a render, `SessionProvider` is a component, `t` is a
 * translator. Exposing them as invocable actions (as a naive
 * "every function prop" rule would) hands the host a way to crash the page.
 */
const FRAMEWORK_PROP_KEYS: ReadonlySet<string> = new Set([
  'renderSlot', 'renderSlotChain', 'SessionProvider', 't', 'matched', 'sessionId', '__renders',
])

/** Selector hooks synthesized from a `hooks` compartment are named `use<Name>`. */
const HOOK_PROP = /^use[A-Z]/

/**
 * Extract the invocable share of a props object.
 * @param props - the composed props the framework passed the entry.
 * @returns the callable injection face, keyed by action name.
 */
export function pickActions(props: Record<string, unknown>): Record<string, SlotAction> {
  const out: Record<string, SlotAction> = {}
  for (const [key, value] of Object.entries(props)) {
    if (typeof value !== 'function') continue
    if (FRAMEWORK_PROP_KEYS.has(key)) continue
    if (HOOK_PROP.test(key)) continue
    out[key] = value as SlotAction
  }
  return out
}

/** A live proxy instance, as tracked between `slot/mount` and `slot/unmount`. */
export interface LiveInstance {
  slot: string
  /** False for `mirrored` instances: they carry lifecycle only (§5). */
  invocable: boolean
  actions: Record<string, SlotAction>
}

/** The instance ledger: also the `slot → instanceId` map `slot/error` needs. */
export interface InstanceLedger {
  /**
   * Record a mounted instance.
   * @returns disposer removing it (called from the unmount path).
   */
  mount(instanceId: string, instance: LiveInstance): () => void
  /** Refresh the action table of a live instance (props changed identity). */
  refresh(instanceId: string, actions: Record<string, SlotAction>): void
  /** Action names of an instance, in declaration order. */
  names(instanceId: string): string[]
  /** Slot name of an instance, or undefined once unmounted. */
  slotOf(instanceId: string): string | undefined
  /** Live instance ids of a slot (a keyed/list slot has several). */
  instancesOf(slot: string): string[]
  /** Number of live instances (diagnostics + leak assertions in tests). */
  readonly size: number
  /**
   * Execute one `slot/invoke`.
   * @throws BridgeFailure with a closed-set code (§1.5).
   */
  invoke(call: { instanceId: string; action: string; args: readonly unknown[]; slot?: string }): unknown
}

/**
 * Create an instance ledger.
 * @returns the ledger face.
 */
export function createInstanceLedger(): InstanceLedger {
  const live = new Map<string, LiveInstance>()

  return {
    get size() { return live.size },

    mount(instanceId, instance) {
      // Re-mounting the same instanceId is a props refresh, never a second
      // view (§1.4).
      live.set(instanceId, instance)
      return () => {
        if (live.get(instanceId) === instance) live.delete(instanceId)
      }
    },

    refresh(instanceId, actions) {
      const instance = live.get(instanceId)
      if (instance === undefined) return
      instance.actions = actions
    },

    names(instanceId) {
      return Object.keys(live.get(instanceId)?.actions ?? {})
    },

    slotOf(instanceId) {
      return live.get(instanceId)?.slot
    },

    instancesOf(slot) {
      return [...live.entries()].filter(([, instance]) => instance.slot === slot).map(([id]) => id)
    },

    invoke({ instanceId, action, args, slot }) {
      const instance = live.get(instanceId)
      if (instance === undefined) {
        throw bridgeError('slot_not_mounted', `instance "${instanceId}" is not mounted`)
      }
      if (slot !== undefined && slot !== instance.slot) {
        throw bridgeError('bad_payload', `instance "${instanceId}" belongs to "${instance.slot}", not "${slot}"`)
      }
      if (!instance.invocable) {
        throw bridgeError(
          'slot_not_declared',
          `slot "${instance.slot}" is not declared native; a mirrored instance exposes no injection face`,
        )
      }
      const fn = instance.actions[action]
      if (fn === undefined) {
        throw bridgeError('unknown_method', `instance "${instanceId}" exposes no action "${action}"`)
      }
      return fn(...args)
    },
  }
}

/**
 * Install the `slot/invoke` handler.
 * @param bridge - control channel.
 * @param ledger - instance ledger.
 * @returns disposer removing the handler.
 */
export function installInvokeHandler(bridge: Bridge, ledger: InstanceLedger): () => void {
  return bridge.handle('slot/invoke', (payload) => {
    const instanceId = expectString(payload, 'instanceId')
    const action = expectString(payload, 'action')
    const slot = optionalString(payload, 'slot')
    const args = optionalArray(payload, 'args') ?? []
    const returned = ledger.invoke({ instanceId, action, args, ...(slot === undefined ? {} : { slot }) })
    // Callbacks are void or promise-of-void in practice; a value is projected
    // onto the JSON domain so a non-serializable return cannot wedge the
    // receipt.
    return Promise.resolve(returned).then((value): { returned: JsonValue } => ({ returned: jsonSafe(value) }))
  })
}
