/**
 * Platform-neutral entry of `studio-client`.
 *
 * The `./client` entry pulls React in and is only loadable in the browser
 * half; this one exports the **wire contract** alone, so the host half (and a
 * Swift code generator, later) can depend on the same declarations without
 * importing a single React symbol. Nothing here has a runtime cost beyond the
 * two frozen tables.
 *
 * It is also this package's **host loader row**: `dsh.client` packages are
 * ordinary rows in the plugin tree whose node half exists so the row can exist
 * (upstream's own `ui-sidebar/src/index.ts` is the same two lines), while the
 * browser half is fetched from `exports["./client"]` through the BootManifest.
 */

export {
  BRIDGE_ERROR_CODES, CONFIGURE_TIMEOUT_MS, INBOUND_METHODS, OUTBOUND_EVENTS,
  PROTOCOL_VERSION, REQUEST_TIMEOUT_MS, timeoutFor,
} from './client/bridge.ts'
export type {
  BridgeErrorCode, InboundMethod, OutboundEvent, OutboundEventPayloads,
  SurveyedSlot, WireError, WireRect, WireScope,
} from './client/bridge.ts'
export { HEARTBEAT_INTERVAL_MS, HEARTBEAT_MISS_THRESHOLD } from './client/heartbeat.ts'
export type { PingPayload, PongPayload } from './client/heartbeat.ts'
export type {
  ConfigureResult, Manifest, Rejection, SlotEntry, SlotEntrySelf, SlotMode,
} from './client/manifest.ts'
export { MIRRORED_PRIORITY, DEFAULT_SHADOW_PRIORITY, PLACEMENTS, SLOT_MODES } from './client/manifest.ts'
export type { Placement } from './client/native-slot.tsx'

/**
 * Host loader entry point. The client half runs in the browser, so there is
 * nothing to do in the dsh process — the row exists so `dsh-client-modules`
 * scans this package into `window.__DSH_BOOT__`.
 */
export function apply(): void {}
