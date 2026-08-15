import assert from 'node:assert/strict'
import { test } from 'node:test'

import { openSettings } from '../src/open-settings.js'

test('openSettings clicks the settings-area trigger', () => {
  let clicked = 0
  const trigger = { click() { clicked += 1 } }
  const doc = {
    querySelector(sel) {
      return sel.includes('settingsArea') ? trigger : null
    },
  }
  assert.deepEqual(openSettings(doc), {})
  assert.equal(clicked, 1)
})

test('openSettings falls back to any dialog trigger', () => {
  let clicked = 0
  const trigger = { click() { clicked += 1 } }
  const doc = {
    querySelector(sel) {
      return sel === 'button[aria-haspopup="dialog"]' ? trigger : null
    },
  }
  openSettings(doc)
  assert.equal(clicked, 1)
})

test('openSettings fails loud when the trigger is missing', () => {
  assert.throws(() => openSettings({ querySelector: () => null }), /not found/)
})
