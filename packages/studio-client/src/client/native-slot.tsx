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
import type { Bridge, WireGeometry, WireRect, WireScope } from './bridge.ts'
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
 * @param props - composed props handed to the entry by the framework. Typed
 * `object` rather than `Record<string, unknown>` because upstream's composed
 * props are intersections of *interfaces* and therefore have no implicit index
 * signature — a record-typed parameter would refuse the real props (see
 * {@link ProxyProps}).
 * @returns only whitelisted, JSON-safe members.
 */
export function serializeOrchestration(props: object): Record<string, unknown> {
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
 * Overflow values that clip a descendant.
 *
 * A superset of {@link SCROLLABLE_OVERFLOW}: `hidden` and `clip` never scroll,
 * but they do cut the slot's box — which is exactly the distinction the host
 * needs. The official sidebar's region seat is `overflow: hidden`, so treating
 * "clips" and "scrolls" as one bit (the shape of the first `slot/rect`) forced a
 * choice between two wrong answers: refuse the cell as an ADR-0003 violation, or
 * let the native view spill over the conversation while the column animates.
 */
const CLIPPING_OVERFLOW: ReadonlySet<string> = new Set([...SCROLLABLE_OVERFLOW, 'hidden', 'clip'])

/**
 * ADR-0003 in executable form: report honestly whether the proxy sits inside a
 * scroll container. The host rejects a geometry-driven placement inside one
 * outright, so the violation crashes in development instead of drifting in
 * front of a user.
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

/** @returns the intersection of two rects; zero-sized when they miss. */
function intersect(a: WireRect, b: WireRect): WireRect {
  const x = Math.max(a.x, b.x)
  const y = Math.max(a.y, b.y)
  const right = Math.min(a.x + a.w, b.x + b.w)
  const bottom = Math.min(a.y + a.h, b.y + b.h)
  return { x, y, w: Math.max(0, right - x), h: Math.max(0, bottom - y) }
}

/** @returns a DOMRect as the wire shape. */
function toWire(rect: { x: number; y: number; width: number; height: number }): WireRect {
  return { x: rect.x, y: rect.y, w: rect.width, h: rect.height }
}

/**
 * Is the box completely covered by something that is not the proxy's own
 * lineage?
 *
 * Hit testing, not z-index arithmetic: stacking contexts, portals and
 * `position: fixed` scrims make a computed z-order unreliable, whereas
 * "what would a click at this point reach" is the browser's own answer to the
 * same question. The placeholder is `visibility: hidden` and therefore never
 * hit itself, so a *bare* cell reports its nearest visible ancestor — which is
 * why an ancestor hit counts as "nothing on top".
 *
 * Every sample must be covered before the cell is declared occluded: a partial
 * cover (a dropdown overlapping one corner) is a case where the native view
 * should stay, and the host clips it instead.
 * @param element - the placeholder element.
 * @param box - the visible box to sample, in viewport coordinates.
 * @returns true only when every sample lands on foreign content.
 */
export function isOccluded(element: Element, box: WireRect): boolean {
  if (box.w <= 2 || box.h <= 2) return false
  const document = element.ownerDocument
  const samples = [
    { x: box.x + box.w / 2, y: box.y + box.h / 2 },
    { x: box.x + 1, y: box.y + 1 },
    { x: box.x + box.w - 1, y: box.y + 1 },
    { x: box.x + 1, y: box.y + box.h - 1 },
    { x: box.x + box.w - 1, y: box.y + box.h - 1 },
  ]
  for (const point of samples) {
    let hit: Element | null
    try {
      // jsdom has no layout and no `elementFromPoint`; an environment that
      // cannot answer must not be read as "occluded" — that would blank the
      // native view. Unknown resolves toward keeping it visible.
      hit = document.elementFromPoint(point.x, point.y)
    } catch {
      return false
    }
    if (hit === null) return false
    if (hit === element || hit.contains(element) || element.contains(hit)) return false
  }
  return true
}

/**
 * Measure one reserved cell.
 *
 * Pure with respect to the DOM (reads only), so the host-side arithmetic and
 * this measurement can be reasoned about separately: this half answers "where
 * is the cell in CSS px", the Swift half answers "where is that in points".
 * @param element - the placeholder element.
 * @returns the geometry `slot/rect` carries.
 */
export function measureGeometry(element: Element): WireGeometry {
  const view = element.ownerDocument.defaultView
  const rect = toWire(element.getBoundingClientRect())
  const viewport = {
    w: view?.innerWidth ?? rect.w,
    h: view?.innerHeight ?? rect.h,
  }
  // The viewport is the last clipping ancestor: nothing outside it is painted.
  let clip: WireRect = { x: 0, y: 0, w: viewport.w, h: viewport.h }
  let scrollable = false
  for (let current = element.parentElement; current !== null; current = current.parentElement) {
    const style = view?.getComputedStyle(current)
    if (style === undefined) continue
    if (SCROLLABLE_OVERFLOW.has(style.overflowY) || SCROLLABLE_OVERFLOW.has(style.overflowX)) {
      scrollable = true
    }
    if (CLIPPING_OVERFLOW.has(style.overflowY) || CLIPPING_OVERFLOW.has(style.overflowX)) {
      // Border box rather than padding box: the difference is the ancestor's
      // border width, and a clipping ancestor with a border would over-report
      // by that much. Kept simple on purpose — the alternative is reading four
      // computed border widths per ancestor on every scroll frame.
      clip = intersect(clip, toWire(current.getBoundingClientRect()))
    }
  }
  return {
    rect,
    clip,
    viewport,
    scrollable,
    occluded: isOccluded(element, intersect(rect, clip)),
    dpr: view?.devicePixelRatio ?? 1,
  }
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

/**
 * Props a slot component receives, as narrowly as the proxy can state them.
 *
 * The proxy never reads a member by name — it only *iterates* the bag — so the
 * ideal type would be `object`. It declares `renderSlot` anyway because
 * upstream's `register` runs a `RendersCheck<C, D>`: an entry that declares
 * child slots must consume `renderSlot`, or the component type is rejected. A
 * `Record<string, unknown>` would satisfy that check too, but it cannot *accept*
 * upstream's composed props (an intersection of interfaces has no implicit index
 * signature), so this is the shape that passes both directions.
 *
 * That the proxy accepts `renderSlot` without calling it is exactly why manifest
 * rule 7 exists: a native parent renders no official child, so every declared
 * child must already be Studio's before the takeover is allowed.
 */
export interface ProxyProps {
  /** Upstream's child-render seat. Never invoked here (see above). */
  renderSlot?: unknown
}

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
    //
    // This is the channel that makes "the Web reserves the cell, the native
    // view fills it" work. It runs for `overlay` and only for `overlay`:
    // `evacuated` takes no room in the Web layout, so it has no rect to report
    // and the host rejects one as a protocol violation.
    useLayoutEffect(() => {
      if (placement !== 'overlay') return
      const element = hostRef.current
      if (element === null) return
      const view = element.ownerDocument.defaultView

      // Deduplicate: a re-measure that finds the same geometry sends nothing.
      // The listeners below fire on every scroll and resize frame of the whole
      // document, and the overwhelming majority of those do not move this cell
      // — forwarding them anyway would turn the control channel into a firehose
      // and hide the events that matter (bridge-contract.md §1.4 is idempotent
      // orchestration, not a stream to be filled).
      let previous = ''
      const report = (): void => {
        const geometry = measureGeometry(element)
        const encoded = JSON.stringify(geometry)
        if (encoded === previous) return
        previous = encoded
        bridge.emit('slot/rect', { instanceId, ...geometry })
      }
      report()

      // Three sources move a cell, and only the first is a resize:
      //   1. the cell (or its content) changes size   → ResizeObserver
      //   2. the window changes size                  → resize
      //   3. an ancestor scrolls                      → scroll (capture: scroll
      //      does not bubble, so a listener on document must capture)
      const observer = view?.ResizeObserver === undefined
        ? undefined
        : new view.ResizeObserver(report)
      observer?.observe(element)
      view?.addEventListener('resize', report)
      element.ownerDocument.addEventListener('scroll', report, { capture: true, passive: true })
      return () => {
        observer?.disconnect()
        view?.removeEventListener('resize', report)
        element.ownerDocument.removeEventListener('scroll', report, { capture: true })
      }
    }, [instanceId])

    if (placement === 'evacuated') {
      // The screen area belongs to the native chrome; the Web side takes none.
      return <div data-studio-slot={slot} style={{ display: 'none' }} />
    }
    // overlay: an invisible placeholder that reserves the very cell the
    // official parent would have given its own occupant, and reports it.
    //
    // The three flex properties are the whole trick. A bare `<div>` in a flex
    // column collapses to zero height, so the reserved rect would be a
    // full-width 0px line — the native view then has nowhere to go, which is
    // precisely how the first W1 build ended up with a 150px-tall sidebar that
    // did not reach the footer. `flex: 1 1 auto` + `align-self: stretch` +
    // `min-*: 0` is what the official occupants declare themselves
    // (`WorkspaceBrowser.module.css .root { flex: 1; min-height: 0 }`), so the
    // placeholder gets a box identical to theirs — in a flex row, a flex
    // column, or a block parent alike.
    return (
      <div
        ref={hostRef}
        data-studio-slot={slot}
        style={{
          visibility: 'hidden',
          flex: '1 1 auto',
          alignSelf: 'stretch',
          minWidth: 0,
          minHeight: 0,
        }}
      />
    )
  }

  NativeSlotProxy.displayName = `NativeSlotProxy(${slot})`
  return NativeSlotProxy
}

/** Re-exported so a host composition can build its own ledger (tests do). */
export { createInstanceLedger }
