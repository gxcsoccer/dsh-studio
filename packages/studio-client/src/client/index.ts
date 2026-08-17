/**
 * `studio-client` — the Cordis client plugin that runs inside the WKWebView.
 *
 * Composition root and nothing else: it wires the control channel
 * (`bridge.ts`), the instance ledger (`invoke.ts`), the proxy component
 * (`native-slot.tsx`) and the manifest resolver (`manifest.ts`) onto the
 * official `ctx.slots` seam, then hands the host a handshake.
 *
 * What it deliberately does NOT do (ARCHITECTURE.md §3, ADR-0001/0002):
 *   - no CSS injection, no DOM surgery on official nodes;
 *   - no domain data over the control channel — sessions, messages and
 *     workspaces travel the 127.0.0.1 data channel that `studio-surface`
 *     serves;
 *   - no fork of an official plugin: every takeover is a registration at a
 *     lower priority on a slot the official code already declared.
 *
 * Failure posture: if the page is not hosted by Studio (a plain browser, a
 * test runner, the official web build) the plugin stays inert and the official
 * UI renders untouched — that is ADR-0004's fallback, and it is the reason
 * every Studio artifact is additive.
 */

import type { ClientContext, ErasedRegisterOptions } from '@deepseek-ai/dsh-client-runtime/client'
import type { LiveSlotNode, StoredEntry } from '@deepseek-ai/dsh-client-ui-slots'
import {
  createBridge, installReceiver, webkitTransport, PROTOCOL_VERSION,
  type Bridge, type BridgeTransport, type ReceiverScope,
  type SurveyedSlot, type WebkitScope, type WireScope,
} from './bridge.ts'
import { createInstanceLedger, installInvokeHandler, type InstanceLedger } from './invoke.ts'
import {
  createManifestController, type ManifestController, type ManifestRuntime, type SlotEnvironment,
} from './manifest.ts'
import { nativeSlot } from './native-slot.tsx'
import { expectString } from './payload.ts'
import { pinnedContract } from './slots/index.ts'

export type { Bridge, BridgeErrorCode, SurveyedSlot, WireError, WireRect } from './bridge.ts'
export type {
  CellRegistration, ConfigureResult, Manifest, ManifestPlan, Rejection, SlotEntry, SlotMode,
} from './manifest.ts'
export type { Placement } from './native-slot.tsx'
export { PROTOCOL_VERSION } from './bridge.ts'

/**
 * Registrant label attached to every Studio registration. It is what makes a
 * Studio entry identifiable in `ctx.slots.snapshot()` — for the host, for the
 * `slot/probe` answer, and for a human reading the official devtools.
 */
export const REGISTRANT = 'dsh-studio'

/** Required services. `slots` is the only seam Studio touches (ARCHITECTURE.md §3). */
export const inject = ['slots']

/** Client-plugin configuration. */
export interface Config {
  /**
   * Mirror bridge diagnostics to the console. Off by default: payloads are
   * never logged (bridge-contract.md §5, last row).
   */
  diagnostics?: boolean
}

/** Everything the plugin assembles; returned so tests can drive it without a WKWebView. */
export interface StudioClient {
  bridge: Bridge
  ledger: InstanceLedger
  controller: ManifestController
  /** Send `surface/ready` with the measured slot table (§1.1 handshake). */
  announce(): void
}

/** Seams `attachStudio` needs; production values come from `window`. */
export interface AttachOptions {
  /** Web → Native transport. */
  transport: BridgeTransport
  /** Where `__DSH_STUDIO__` is mounted. */
  scope: ReceiverScope
  /** @see Config.diagnostics */
  diagnostics?: boolean
}

/**
 * Flatten `ctx.slots.snapshot()` into the wire slot table.
 *
 * The handshake reports what this build **actually** has, not what the pins
 * believe: the host decides whether to send a manifest at all by comparing the
 * two (ARCHITECTURE.md §7 — a renamed slot must be visible, not guessed).
 * @param roots - snapshot roots.
 * @returns one row per slot, depth-first, sorted by name for a stable wire form.
 */
export function surveySlots(roots: readonly LiveSlotNode[]): SurveyedSlot[] {
  const rows: SurveyedSlot[] = []
  const walk = (node: LiveSlotNode): void => {
    rows.push({
      name: node.name,
      kind: node.kind,
      scope: node.scope,
      occupants: node.occupants.map(occupant => ({
        priority: occupant.priority,
        active: occupant.active,
        ...(occupant.registrant === undefined ? {} : { registrant: occupant.registrant }),
        ...(occupant.key === undefined ? {} : { key: occupant.key }),
        ...(occupant.id === undefined ? {} : { id: occupant.id }),
      })),
    })
    for (const child of node.children) walk(child)
  }
  for (const root of roots) walk(root)
  return rows.sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0))
}

/** Answer of `slot/probe` (§1.3). */
export interface ProbeResult {
  slot: string
  /** False when this build does not declare the slot at all. */
  declared: boolean
  kind?: SurveyedSlot['kind']
  scope?: WireScope
  occupants: SurveyedSlot['occupants']
  /** Live proxy instances of this slot (`slot/invoke` targets). */
  instances: string[]
  /** Cells Studio currently holds, from the manifest controller. */
  studioCells: string[]
}

/**
 * Assemble the client half onto a context.
 *
 * Registration lifetime is owned twice over, deliberately:
 *   - each cell is one `ctx.effect`, so unloading the plugin (or an HMR swap)
 *     un-registers it and the official occupant renders again;
 *   - each cell's body is `ctx.slots.inject(slot, …)`, because
 *     `dsh.client.inject` edges are informational and do NOT sequence
 *     `apply` — upstream's own ui-workspace says so in a comment. Waiting for
 *     the declaration is therefore mandatory, and it makes a `configure`
 *     that arrives before the sidebar plugin loaded resolve correctly instead
 *     of rejecting.
 * @param ctx - client root context.
 * @param options - transport and receiver seams.
 * @returns the assembled client.
 */
export function attachStudio(ctx: ClientContext, options: AttachOptions): StudioClient {
  const diagnose = options.diagnostics === true
    ? (message: string): void => { console.info(`[studio] ${message}`) }
    : (): void => {}

  const ledger = createInstanceLedger()
  const bridge = createBridge({
    transport: options.transport,
    onDiagnostic: diagnose,
    onProtocolMismatch: () => {
      // §4: an unknown `v` is not negotiated and not guessed. Every native
      // takeover is released, which is exactly the ADR-0004 fallback: the
      // official Web UI is still registered underneath and renders again.
      controller.disposeAll()
      diagnose('degraded to the official Web UI after a protocol mismatch')
    },
  })

  const env: SlotEnvironment = {
    spec: slot => ctx.slots.spec(slot),
    entries: slot => ctx.slots.entries(slot),
    pinned: pinnedContract,
  }

  const runtime: ManifestRuntime = {
    env,
    log: diagnose,
    install: (registration) => {
      const component = nativeSlot(bridge, ledger, {
        slot: registration.slot,
        placement: registration.placement,
        scope: registration.scope,
        // §5: only a slot the manifest declared native/retired exposes an
        // injection face; a mirrored passenger stays unreachable.
        invocable: registration.mode !== 'mirrored',
        ...(registration.key === undefined ? {} : { key: registration.key }),
      })
      const registerOptions: ErasedRegisterOptions = {
        name: registration.slot,
        priority: registration.priority,
        registrant: REGISTRANT,
        ...(registration.key === undefined ? {} : { key: registration.key }),
        ...(registration.id === undefined ? {} : { id: registration.id }),
        // Rule 6: children we must declare ourselves. Children the shadowed
        // occupant already declared stay in its ownership (one declarer per
        // slot upstream), which `resolveChildren` recorded as inherited.
        ...(Object.keys(registration.children).length === 0 ? {} : { children: registration.children }),
      }
      const dispose = ctx.effect(
        () => ctx.slots.inject(registration.slot, () => ctx.slots.register(registerOptions, component)),
        `studio: ${registration.cell}`,
      )
      // Cordis runs synchronous disposers synchronously (vendor/cordis
      // fiber.ts `effect`), despite the awaitable signature. That is what
      // makes a hot re-configure safe: the cell is free again before the
      // replacement registers at the same priority.
      return () => { void dispose() }
    },
  }

  const controller = createManifestController(runtime)

  ctx.effect(() => installReceiver(bridge, options.scope), 'studio: __DSH_STUDIO__ receiver')
  ctx.effect(() => installInvokeHandler(bridge, ledger), 'studio: slot/invoke')

  ctx.effect(() => bridge.handle('surface/configure', payload => controller.configure(payload.manifest)),
    'studio: surface/configure')
  ctx.effect(() => bridge.handle('surface/reconfigure', payload => controller.reconfigure(payload.patch)),
    'studio: surface/reconfigure')
  ctx.effect(() => bridge.handle('slot/probe', (payload): ProbeResult => {
    const slot = expectString(payload, 'slot')
    const spec = ctx.slots.spec(slot)
    const row = surveySlots(ctx.slots.snapshot()).find(candidate => candidate.name === slot)
    return {
      slot,
      declared: spec !== undefined,
      ...(spec === undefined ? {} : { kind: spec.kind, scope: spec.scope }),
      occupants: row?.occupants ?? [],
      instances: ledger.instancesOf(slot),
      studioCells: controller.active.filter(cell => cell === slot || cell.startsWith(`${slot}#`)),
    }
  }), 'studio: slot/probe')

  // Error telemetry (§1.3 `slot/error`). Upstream calls this back both for a
  // render failure and for an abdication; the host needs the difference,
  // because an abdicated entry means the cell fell through to the official
  // occupant and the native view must be taken down.
  ctx.effect(() => ctx.slots.onEntryError((slot, entry: StoredEntry, error, info) => {
    const live = ledger.instancesOf(slot)
    // A single-instance slot maps unambiguously; a keyed/list cell would need
    // an instanceId on the entry, which upstream does not carry, so it is
    // omitted rather than guessed.
    const instanceId = live.length === 1 ? live[0] : undefined
    bridge.emit('slot/error', {
      slot,
      ...(instanceId === undefined ? {} : { instanceId }),
      error: error instanceof Error ? error.message : String(error),
      abdicated: info.abdicated,
    })
    diagnose(`entry error on ${slot} (priority ${entry.options.priority ?? 0}, abdicated=${info.abdicated})`)
  }), 'studio: slot/error telemetry')

  return {
    bridge,
    ledger,
    controller,
    announce() {
      bridge.emit('surface/ready', {
        protocol: PROTOCOL_VERSION,
        slots: surveySlots(ctx.slots.snapshot()),
      })
    },
  }
}

/**
 * Plugin entry point.
 * @param ctx - client root context.
 * @param config - plugin configuration.
 */
export function apply(ctx: ClientContext, config: Config = {}): void {
  const scope = globalThis as unknown as WebkitScope & ReceiverScope
  const transport = webkitTransport(scope)
  if (transport === undefined) {
    // Not inside the Studio WKWebView: stay inert. The official UI is
    // untouched (ADR-0004), so a plain browser build keeps working.
    return
  }
  const studio = attachStudio(ctx, {
    transport,
    scope,
    ...(config.diagnostics === undefined ? {} : { diagnostics: config.diagnostics }),
  })
  // The handshake is the last thing that happens: by the time the host may
  // answer with a manifest, every inbound handler is installed.
  studio.announce()
}
