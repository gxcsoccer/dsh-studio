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

/**
 * Mount a container into the shared document.
 * @param options - `scrollable` wraps the tree in a scroll container so the
 * ADR-0003 detection has something to find.
 * @returns the harness.
 */
export function mountHarness(options: { scrollable?: boolean } = {}): Harness {
  const document = dom.window.document
  const container = document.createElement('div')
  if (options.scrollable === true) container.style.overflowY = 'auto'
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

/**
 * Pin `getBoundingClientRect` for the duration of a test (jsdom reports zeros
 * for everything, which would make a geometry assertion vacuous).
 * @param rect - the geometry to report.
 * @returns a restore function.
 */
export function pinGeometry(rect: { x: number; y: number; width: number; height: number }): () => void {
  const prototype = dom.window.HTMLElement.prototype as unknown as { getBoundingClientRect: () => unknown }
  const previous = prototype.getBoundingClientRect
  prototype.getBoundingClientRect = () => ({
    ...rect,
    top: rect.y,
    left: rect.x,
    right: rect.x + rect.width,
    bottom: rect.y + rect.height,
    toJSON: () => rect,
  })
  return () => { prototype.getBoundingClientRect = previous }
}
