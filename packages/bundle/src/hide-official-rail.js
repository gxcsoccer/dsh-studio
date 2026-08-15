/**
 * Hide the official sidebar column in the native window.
 *
 * The settings modal is `position: fixed` inside that column. Unmounting the
 * slot, or `display: none` on an ancestor, would take the modal with it.
 * The layout frame sets `grid-template-columns` as an inline style (56px
 * rail when collapsed). A stylesheet `!important` beats that.
 *
 * Selectors must not depend on a class on `<html>`: the theme boot writes
 * `documentElement.style` and other presenters may replace `className`.
 * A regular browser never calls this.
 */

export const STYLE_ID = 'dsh-studio-hide-rail'

export const RAIL_CSS = `
[class*="_frame"][data-details-collapsed] {
  grid-template-columns: 0px minmax(0, 1fr) 0px !important;
}
[class*="_frame"]:not([data-details-collapsed]) {
  grid-template-columns: 0px minmax(0, 1fr) minmax(300px, 520px) !important;
}
[class*="_sidebarCol"] {
  width: 0 !important;
  max-width: 0 !important;
  min-width: 0 !important;
  padding: 0 !important;
  border: none !important;
  overflow: hidden !important;
}
`

export function zeroSidebarTrack(columns) {
  if (typeof columns !== 'string') return columns
  const trimmed = columns.trim()
  if (!trimmed || /^0(px)?(\s|$)/.test(trimmed)) return columns
  return trimmed.replace(/^\S+/, '0px')
}

export function hideOfficialRail(doc = globalThis.document, Observer = globalThis.MutationObserver) {
  if (!doc?.documentElement) return () => {}

  const apply = () => ensureStyle(doc)
  apply()

  if (typeof Observer !== 'function') return () => {}
  const observer = new Observer(apply)
  observer.observe(doc.documentElement, { subtree: true, childList: true })
  return () => observer.disconnect()
}

function ensureStyle(doc) {
  if (doc.getElementById(STYLE_ID)) return
  const tag = doc.createElement('style')
  tag.id = STYLE_ID
  tag.textContent = RAIL_CSS
  ;(doc.head || doc.documentElement).appendChild(tag)
}
