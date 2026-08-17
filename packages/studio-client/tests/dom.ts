/**
 * DOM harness for the proxy-component tests.
 *
 * `NativeSlotProxy`'s whole job is lifecycle and geometry, so testing it
 * without a document would test nothing. jsdom globals are installed as a
 * module side effect **before** `react-dom` is imported (react-dom decides
 * `canUseDOM` at module evaluation), which is why the react-dom import below
 * is dynamic and why test files must import this module first.
 */

import { JSDOM } from 'jsdom'
import { act, type ReactElement } from 'react'

/** The one document every test in a file shares. */
export const dom = new JSDOM('<!doctype html><html><body></body></html>', {
  pretendToBeVisual: true,
  url: 'http://studio.test/',
})

const window = dom.window as unknown as Record<string, unknown>

// Only the globals react-dom and the proxy actually reach for; a blanket copy
// of the jsdom window would shadow Node builtins (`fetch`, `performance`, …)
// that other tests in the same process rely on.
for (const key of [
  'window', 'document', 'navigator', 'location',
  'Node', 'Element', 'HTMLElement', 'HTMLDivElement', 'Text', 'DocumentFragment', 'DOMRect',
  'Event', 'EventTarget', 'CustomEvent', 'MutationObserver', 'getComputedStyle',
  'requestAnimationFrame', 'cancelAnimationFrame',
]) {
  Object.defineProperty(globalThis, key, { value: window[key], configurable: true, writable: true })
}

// react-dom refuses to run effects outside an act() scope without this.
Object.defineProperty(globalThis, 'IS_REACT_ACT_ENVIRONMENT', { value: true, configurable: true, writable: true })

const { createRoot } = await import('react-dom/client')

/** A mounted React tree plus the affordances the geometry tests need. */
export interface Harness {
  container: HTMLElement
  /** Render (or re-render) the tree, flushing effects. */
  render(element: ReactElement | null): void
  /** Unmount the tree and detach the container. */
  unmount(): void
  /** The proxy's own element, identified by its `data-studio-slot` marker. */
  proxyElement(slot: string): HTMLElement | null
}

/** Ancestor traits a geometry test needs the container to have. */
export interface HarnessOptions {
  /** `overflow-y: auto` — a scroll container, which ADR-0003 refuses. */
  scrollable?: boolean
  /**
   * `overflow: hidden` — clips but never scrolls, like the official sidebar's
   * region seat. Keeping the two apart is the whole point of `clip` on the wire.
   */
  clipping?: boolean
}

/**
 * Mount a container into the shared document.
 * @param options - ancestor traits, so the proxy's chain walk has something to
 * find.
 * @returns the harness.
 */
export function mountHarness(options: HarnessOptions = {}): Harness {
  const document = dom.window.document
  const container = document.createElement('div')
  if (options.scrollable === true) container.style.overflowY = 'auto'
  // Both axes explicitly: jsdom's `getComputedStyle` does not expand the
  // `overflow` shorthand into `overflowX` / `overflowY`, which is what the proxy
  // reads.
  if (options.clipping === true) {
    container.style.overflowX = 'hidden'
    container.style.overflowY = 'hidden'
  }
  document.body.appendChild(container)
  const root = createRoot(container)
  return {
    container,
    render(element) { act(() => { root.render(element) }) },
    unmount() {
      act(() => { root.unmount() })
      container.remove()
    },
    proxyElement(slot) {
      return container.querySelector<HTMLElement>(`[data-studio-slot="${slot}"]`)
    },
  }
}

/** A ResizeObserver double whose callbacks the test fires by hand. */
export interface FakeResizeObservers {
  /** Fire every observer installed so far. */
  trigger(): void
  readonly observed: number
  readonly disconnected: number
  restore(): void
}

/**
 * Install a fake `ResizeObserver` on the jsdom window (jsdom ships none).
 * @returns the control surface; `restore` takes it back off.
 */
export function fakeResizeObservers(): FakeResizeObservers {
  const callbacks = new Set<() => void>()
  let observed = 0
  let disconnected = 0
  class FakeResizeObserver {
    #callback: () => void
    /** @param callback - invoked on every {@link FakeResizeObservers.trigger}. */
    constructor(callback: () => void) {
      this.#callback = callback
    }

    /** Record an observation. */
    observe(): void {
      observed += 1
      callbacks.add(this.#callback)
    }

    /** Stop observing. */
    disconnect(): void {
      disconnected += 1
      callbacks.delete(this.#callback)
    }

    /** Unused half of the real interface. */
    unobserve(): void {
      callbacks.delete(this.#callback)
    }
  }
  const previous = window.ResizeObserver
  window.ResizeObserver = FakeResizeObserver
  return {
    trigger() { for (const callback of [...callbacks]) act(() => { callback() }) },
    get observed() { return observed },
    get disconnected() { return disconnected },
    restore() { window.ResizeObserver = previous },
  }
}

/** A rect as the tests state it. */
export interface PinnedRect { x: number; y: number; width: number; height: number }

/** Control surface of {@link pinGeometry}. */
export interface PinnedGeometry {
  /** Change the rect every non-overridden element reports. */
  set(rect: PinnedRect): void
  /**
   * Report a different rect for one element — how a clipping ancestor is
   * expressed, since the proxy measures the ancestor chain as well as itself.
   */
  setFor(element: Element, rect: PinnedRect): void
  restore(): void
}

/**
 * Pin `getBoundingClientRect` for the duration of a test (jsdom reports zeros
 * for everything, which would make a geometry assertion vacuous).
 * @param rect - the geometry every element reports by default.
 * @returns the control surface; `restore` puts the real method back.
 */
export function pinGeometry(rect: PinnedRect): PinnedGeometry {
  const prototype = dom.window.HTMLElement.prototype as unknown as { getBoundingClientRect: () => unknown }
  const previous = prototype.getBoundingClientRect
  const overrides = new WeakMap<Element, PinnedRect>()
  let fallback = rect
  const expand = (value: PinnedRect): unknown => ({
    ...value,
    top: value.y,
    left: value.x,
    right: value.x + value.width,
    bottom: value.y + value.height,
    toJSON: () => value,
  })
  prototype.getBoundingClientRect = function (this: Element) {
    return expand(overrides.get(this) ?? fallback)
  }
  return {
    set(next) { fallback = next },
    setFor(element, next) { overrides.set(element, next) },
    restore() { prototype.getBoundingClientRect = previous },
  }
}

/**
 * Install a `document.elementFromPoint` double (jsdom has no layout and ships
 * none, so the proxy's occlusion sampling bails out to "visible" by default).
 * @param hit - what a sample at any point lands on; `null` means nothing.
 * @returns a restore function.
 */
export function pinHitTest(hit: Element | null): () => void {
  const target = dom.window.document as unknown as Record<string, unknown>
  const previous = target.elementFromPoint
  target.elementFromPoint = () => hit
  return () => { target.elementFromPoint = previous }
}

