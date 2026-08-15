/**
 * Open the official settings modal.
 *
 * Open state is component-local inside `ui-settings-general` — there is no
 * `ctx.settings.open`. The trigger is still in the official sidebar (even
 * when that column is a rail), and the panel itself is `position: fixed`,
 * so a programmatic click is enough. Native chrome just needs a door.
 */

export function openSettings(doc = globalThis.document) {
  if (!doc?.querySelector) {
    throw new Error('openSettings needs a document')
  }
  const trigger =
    doc.querySelector('[class*="settingsArea"] button[aria-haspopup="dialog"]') ||
    doc.querySelector('button[aria-haspopup="dialog"]')
  if (!trigger || typeof trigger.click !== 'function') {
    throw new Error('settings trigger not found')
  }
  trigger.click()
  return {}
}
