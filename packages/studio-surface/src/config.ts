/**
 * `studio-surface` configuration — the **control plane** of the whole
 * architecture (surface-manifest.md §1).
 *
 * The surface manifest lives here, in a plugin `Config`, and nowhere else.
 * That single decision buys three things upstream already built and we would
 * otherwise have to reinvent: hot rollback (edit one line, official UI is
 * back, no release), comparison runs (`mirrored`), and user sovereignty — a
 * user who dislikes the native sidebar writes one line in
 * `cordis.patch.yml` instead of filing an issue (§6).
 *
 * Two things are deliberately NOT configurable:
 *   - the bind address: `127.0.0.1` is asserted in code (bridge-contract.md §5);
 *   - anything in surface-manifest.md §7 (selectors, pixel geometry, domain
 *     filters, a fifth "hidden" mode).
 */

import z from '@deepseek-ai/schemastery'
import type { Manifest, SlotEntry as WireSlotEntry } from '@dsh-studio/studio-client/src/index.ts'

/** Default data-channel port (bridge-contract.md §2.1). */
export const DEFAULT_BRIDGE_PORT = 43180

/** Default number of forwarded events retained for SSE resume (§2.3). */
export const DEFAULT_RETENTION = 1024

/** The only address the data channel may bind (§2.1, §5). */
export const LOOPBACK_ADDRESS = '127.0.0.1'

/** Slot state machine (surface-manifest.md §2). */
export type SlotMode = 'web' | 'mirrored' | 'native' | 'retired'

/** Landing form of a native view (ARCHITECTURE.md §4). */
export type Placement = 'evacuated' | 'overlay'

/**
 * `web` renders officially and we register nothing; `mirrored` rides along at a
 * higher priority; `native` and `retired` win the cell. `retired` differs from
 * `native` only in intent — the official implementation is no longer
 * meaningful for this product — and that difference is what makes the
 * migration ledger auditable (`grep -c 'mode: retired'`).
 */
export const SlotModeSchema: z<SlotMode> = z.union([
  z.const('web'),
  z.const('mirrored'),
  z.const('native'),
  z.const('retired'),
])

/** `evacuated` is the default and the preferred form; `overlay` is restricted (ADR-0003). */
export const PlacementSchema: z<Placement> = z.union([
  z.const('evacuated'),
  z.const('overlay'),
])

/** Per-key / per-id override. */
export interface SlotEntrySelf {
  mode?: SlotMode
  placement?: Placement
  priority?: number
}

/**
 * A nested override carries **no defaults**.
 *
 * This is a deliberate divergence from the schema sketch in
 * surface-manifest.md §2, which reuses the defaulted entry shape for `keys` /
 * `ids`. Schemastery materializes defaults, so a defaulted `mode` would turn
 * `keys: { unknown: {} }` into an explicit `mode: web` and make rule 5's
 * "parent mode is the default for unlisted keys" unreachable for a listed but
 * empty key. Absent stays absent here, and rule 5 does the inheriting.
 */
export const SlotEntrySelfSchema: z<SlotEntrySelf> = z.object({
  mode: SlotModeSchema,
  placement: PlacementSchema,
  priority: z.number().step(1),
})

/** One manifest row. */
export interface SlotEntry {
  mode: SlotMode
  placement: Placement
  priority: number
  /** Per-key configuration; `keyed` slots only. */
  keys: Record<string, SlotEntrySelf>
  /** Per-registration-id configuration; `list` slots only. */
  ids: Record<string, SlotEntrySelf>
}

/**
 * Row defaults: `web` (rule 1 — never touch the official UI unless asked),
 * `evacuated` (the placement that needs no geometry), and priority `-1` (one
 * below the official default of 0).
 */
export const SlotEntrySchema: z<SlotEntry> = z.object({
  mode: SlotModeSchema.default('web'),
  placement: PlacementSchema.default('evacuated'),
  priority: z.number().step(1).default(-1),
  keys: z.dict(SlotEntrySelfSchema).default({}),
  ids: z.dict(SlotEntrySelfSchema).default({}),
}) as z<SlotEntry>

/** Data-channel settings. */
export interface BridgeConfig {
  port: number
  /**
   * Forwarded events kept for `Last-Event-ID` resume. Beyond this window the
   * host is told to re-baseline through `session.history` instead of being
   * handed a silent gap (§2.3).
   */
  retention: number
  /**
   * Absolute path of the handshake file. Empty means
   * `$DSH_HOME/studio/bridge.json` resolved through the host's own
   * `ctx.dshHomePath`; Studio never re-derives `$DSH_HOME` itself.
   */
  tokenFile: string
  /**
   * URL of the official Web shell, published to the native half as the
   * handshake's `webUrl` (bridge-contract.md §2.1).
   *
   * It is configuration rather than something this plugin derives, and that is
   * a deliberate boundary: the address the browser must use is decided by the
   * web bundle's own rows (`webserver` host/port, a reverse proxy in front of
   * them, an SSH tunnel), and none of that is knowable from inside a plugin
   * that only injects `apiProxy`. Empty (the default) publishes no `webUrl` at
   * all — the honest answer, which the native half reports as "no shell
   * address yet" instead of loading a wrong page.
   */
  shellUrl: string
}

/** Plugin configuration. */
export interface Config {
  bridge: BridgeConfig
  /** The surface manifest: `slot → row`. */
  surface: Record<string, SlotEntry>
  /**
   * Hotkey flipping the focused slot between `native` and `web`. It is a user
   * self-rescue channel first and a dev tool second, which is also why the
   * flip-back rate is the most honest acceptance metric (§5).
   */
  compareHotkey: string
}

/** Configuration schema (validated, defaulted, and rendered by the official settings panel). */
export const Config: z<Config> = z.object({
  bridge: z.object({
    // No `host` member: the bind address is asserted in code, not configured.
    port: z.natural().default(DEFAULT_BRIDGE_PORT),
    retention: z.natural().default(DEFAULT_RETENTION),
    tokenFile: z.string().default(''),
    shellUrl: z.string().default(''),
  }),
  surface: z.dict(SlotEntrySchema).default({}),
  compareHotkey: z.string().default('opt+shift+d'),
}) as z<Config>

/**
 * Project the configured manifest onto the control-channel wire form.
 *
 * Empty `keys` / `ids` tables are dropped: they are a schema artifact, and
 * sending them would make an unrelated slot look like a keyed one in the
 * client's rule-5 expansion.
 * @param config - resolved plugin configuration.
 * @returns the manifest as `surface/configure` carries it.
 */
export function toWireManifest(config: Config): Manifest {
  const manifest: Manifest = {}
  for (const [slot, entry] of Object.entries(config.surface)) {
    const row: WireSlotEntry = {
      mode: entry.mode,
      placement: entry.placement,
      priority: entry.priority,
    }
    if (Object.keys(entry.keys).length > 0) row.keys = entry.keys
    if (Object.keys(entry.ids).length > 0) row.ids = entry.ids
    manifest[slot] = row
  }
  return manifest
}

/**
 * Count the migration state, so the ledger is derived from the live config
 * instead of a hand-maintained table (migration-ledger.md).
 * @param config - resolved plugin configuration.
 * @returns how many rows sit in each mode.
 */
export function surfaceCensus(config: Config): Record<SlotMode, number> {
  const census: Record<SlotMode, number> = { web: 0, mirrored: 0, native: 0, retired: 0 }
  for (const entry of Object.values(config.surface)) census[entry.mode] += 1
  return census
}

/** Compile-time assertion carrier. */
type Expect<T extends true> = T

/**
 * The configured row must be a legal wire row. This is the seam where the host
 * config and the client parser could drift apart, so it is checked by the
 * compiler rather than by a test: the config side is total (schemastery fills
 * every default) and the wire side is partial, so assignability — not
 * equality — is the correct relation.
 */
export type AssertRowIsWireCompatible = Expect<SlotEntry extends WireSlotEntry ? true : false>
