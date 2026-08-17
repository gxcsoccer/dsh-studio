/**
 * Platform-neutral entry of `studio-client`.
 *
 * The `./client` entry pulls React in and is only loadable in the browser
 * half; this one exports the **wire contract** alone, so the host half (and a
 * Swift code generator, later) can depend on the same declarations without
 * importing a single React symbol. Nothing here has a runtime cost beyond the
 * two frozen tables.
 */

export {
  BRIDGE_ERROR_CODES, CONFIGURE_TIMEOUT_MS, INBOUND_METHODS, OUTBOUND_EVENTS,
  PROTOCOL_VERSION, REQUEST_TIMEOUT_MS, timeoutFor,
} from './client/bridge.ts'
export type {
  BridgeErrorCode, InboundMethod, OutboundEvent, OutboundEventPayloads,
  SurveyedSlot, WireError, WireRect, WireScope,
} from './client/bridge.ts'
export type {
  ConfigureResult, Manifest, Rejection, SlotEntry, SlotEntrySelf, SlotMode,
} from './client/manifest.ts'
export { MIRRORED_PRIORITY, DEFAULT_SHADOW_PRIORITY, PLACEMENTS, SLOT_MODES } from './client/manifest.ts'
export type { Placement } from './client/native-slot.tsx'
