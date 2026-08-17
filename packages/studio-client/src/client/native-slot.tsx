/**
 * `NativeSlotProxy` — the one and only generic proxy component
 * (reference/native-slot-proxy.md §1, migration-playbook.md §6).
 *
 * It does four things and nothing else:
 *   mount   → evt slot/mount
 *   update  → evt slot/props   (shallow diff)
 *   measure → evt slot/rect    (overlay only, ResizeObserver driven)
 *   unmount → evt slot/unmount
 *
 * It does NOT: read domain data, cache state, query the DOM for official
 * nodes, inject CSS, or branch on a concrete slot name. Every slot in the
 * migration reuses this file verbatim; if a slot needs a change here, the
 * playbook says stop and re-derive the placement instead (§0).
 */

import { useLayoutEffect, useRef, type ReactElement } from 'react'
import type { Bridge, WireScope } from './bridge.ts'
import { createInstanceLedger, pickActions, type InstanceLedger } from './invoke.ts'
import { jsonSafe } from './payload.ts'
import { ulid } from './ulid.ts'

/** Placement of a native view relative to the Web layout (ARCHITECTURE.md §4). */
export type Placement = 'evacuated' | 'overlay'

/**
 * Whitelist of props allowed across the control channel — the executable form
 * of ADR-0002.
 *
 * A whitelist, not a blacklist: a blacklist gets hollowed out one "this field
 * is small, let it through" at a time over dozens of slot migrations, whereas
 * every addition here has to be argued for in review.
 *
 * `wide` is the `sidebar.workspaces` fold-state fact
 * (upstream `SidebarSectionOwnerProps.wide`); it is orchestration, not domain
 * data. It is absent from the reference list in the design docs — see the W1
 * report.
 */
export const ORCHESTRATION_KEYS: ReadonlySet<string> = new Set([
  'collapsed', 'selected', 'expanded', 'width', 'disabled',
  'placeholder', 'variant', 'order', 'label', 'wide',
])

/**
 * Project props onto the orchestration share.
 * @param props - composed props handed to the entry by the framework.
 * @returns only whitelisted, JSON-safe members.
 */
export function serializeOrchestration(props: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(props)) {
    if (typeof value === 'function') continue      // callbacks ride slot/invoke
    if (!ORCHESTRATION_KEYS.has(key)) continue     // domain data rides the data channel
    if (value === undefined) continue
    out[key] = jsonSafe(value)
  }
  return out
}

/**
 * Shallow diff of two orchestration snapshots.
 * @param prev - previous snapshot.
 * @param next - current snapshot.
 * @returns changed members only; a member that disappeared is reported as null
 * (the host applies the patch onto its own projection, so it must be able to
 * see a removal).
 */
export function shallowDiff(
  prev: Record<string, unknown>,
  next: Record<string, unknown>,
): Record<string, unknown> {
  const patch: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(next)) {
    if (!Object.is(prev[key], value)) patch[key] = value
  }
  for (const key of Object.keys(prev)) {
    if (!(key in next)) patch[key] = null
  }
  return patch
}

/** Overflow values that make an element a scroll container. */
const SCROLLABLE_OVERFLOW: ReadonlySet<string> = new Set(['auto', 'scroll', 'overlay'])

/**
 * ADR-0003 in executable form: report honestly whether the proxy sits inside a
 * scroll container. The host rejects `overlay` + `scrollable` outright, so the
 * violation crashes in development instead of drifting in front of a user.
 * @param element - the placeholder element.
 * @returns true when any ancestor (up to and including the document element)
 * scrolls.
 */
export function hasScrollableAncestor(element: Element): boolean {
  const view = element.ownerDocument.defaultView
  if (view === null) return false
  let current: Element | null = element.parentElement
  while (current !== null) {
    const style = view.getComputedStyle(current)
    if (SCROLLABLE_OVERFLOW.has(style.overflowY) || SCROLLABLE_OVERFLOW.has(style.overflowX)) return true
    current = current.parentElement
  }
  return false
}

/** Registration facts a proxy instance needs; all of them come from the manifest. */
export interface NativeSlotOptions {
  slot: string
  placement: Placement
  scope: WireScope
  /**
   * Whether the host may drive this instance's injection face: true for
   * `native` / `retired`, false for `mirrored` (bridge-contract.md §5).
   */
  invocable: boolean
  /**
   * Cell key of a `keyed` registration. It comes from the registration
   * options, NOT from props — React reserves `props.key` and never delivers it
   * to a component (see the W1 report).
   */
  key?: string
}

/** Props a slot component receives: an opaque record as far as the proxy cares. */
export type ProxyProps = Record<string, unknown>

/**
 * Build the proxy component of one registration.
 * @param bridge - control channel.
 * @param ledger - instance ledger backing `slot/invoke` and `slot/error`.
 * @param options - registration facts.
 * @returns a React component honoring the "four things only" contract.
 */
export function nativeSlot(
  bridge: Bridge,
  ledger: InstanceLedger,
  options: NativeSlotOptions,
): (props: ProxyProps) => ReactElement {
  const { slot, placement, scope, invocable } = options

  function NativeSlotProxy(props: ProxyProps): ReactElement {
    const hostRef = useRef<HTMLDivElement | null>(null)
    const prevRef = useRef<Record<string, unknown>>({})
    const propsRef = useRef<ProxyProps>(props)
    propsRef.current = props

    // The instanceId is minted during render, not inside an effect: layout
    // effects run before passive effects, so an id minted in a passive mount
    // effect would still be undefined when the geometry effect fires. One
    // instanceId = one native view (§1.4).
    const idRef = useRef<string | undefined>(undefined)
    idRef.current ??= ulid()
    const instanceId = idRef.current

    // ── mount / unmount ───────────────────────────────────────────────────
    useLayoutEffect(() => {
      const snapshot = serializeOrchestration(propsRef.current)
      prevRef.current = snapshot
      const actions = pickActions(propsRef.current)
      const release = ledger.mount(instanceId, { slot, invocable, actions })
      bridge.emit('slot/mount', {
        slot,
        instanceId,
        ...(options.key === undefined ? {} : { key: options.key }),
        scope,
        props: snapshot,
        actions: Object.keys(actions),
      })
      return () => {
        release()
        bridge.emit('slot/unmount', { instanceId })
      }
    }, [instanceId])

    // ── props changes ─────────────────────────────────────────────────────
    // The mount effect seeded prevRef with the initial snapshot, so the first
    // run of this effect diffs to empty and sends nothing.
    useLayoutEffect(() => {
      const next = serializeOrchestration(props)
      const patch = shallowDiff(prevRef.current, next)
      prevRef.current = next
      // Callback identities change on every parent render; refresh the table
      // so an invoke always reaches the current closure.
      ledger.refresh(instanceId, pickActions(props))
      if (Object.keys(patch).length > 0) {
        bridge.emit('slot/props', { instanceId, props: patch })
      }
    }, [props, instanceId])

    // ── geometry (overlay only) ───────────────────────────────────────────
    useLayoutEffect(() => {
      if (placement !== 'overlay') return
      const element = hostRef.current
      if (element === null) return
      const scrollable = hasScrollableAncestor(element)
      const report = (): void => {
        const rect = element.getBoundingClientRect()
        bridge.emit('slot/rect', {
          instanceId,
          rect: { x: rect.x, y: rect.y, w: rect.width, h: rect.height },
          scrollable,
        })
      }
      report()
      const view = element.ownerDocument.defaultView
      const Observer = view?.ResizeObserver
      if (Observer === undefined) return
      const observer = new Observer(report)
      observer.observe(element)
      return () => { observer.disconnect() }
    }, [instanceId])

    if (placement === 'evacuated') {
      // The screen area belongs to the native chrome; the Web side takes none.
      return <div data-studio-slot={slot} style={{ display: 'none' }} />
    }
    // overlay: same-size invisible placeholder that keeps the Web layout intact.
    return <div ref={hostRef} data-studio-slot={slot} style={{ visibility: 'hidden' }} />
  }

  NativeSlotProxy.displayName = `NativeSlotProxy(${slot})`
  return NativeSlotProxy
}

/** Re-exported so a host composition can build its own ledger (tests do). */
export { createInstanceLedger }
