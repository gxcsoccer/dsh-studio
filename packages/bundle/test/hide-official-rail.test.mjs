import assert from 'node:assert/strict'
import { test } from 'node:test'

import { hideOfficialRail, RAIL_CSS, STYLE_ID, zeroSidebarTrack } from '../src/hide-official-rail.js'

test('zeroSidebarTrack keeps the details track', () => {
  assert.equal(
    zeroSidebarTrack('56px minmax(0, 1fr) 320px'),
    '0px minmax(0, 1fr) 320px',
  )
  assert.equal(zeroSidebarTrack('0px minmax(0, 1fr) 0px'), '0px minmax(0, 1fr) 0px')
})

test('hideOfficialRail injects a stylesheet that does not depend on html class', () => {
  const children = []
  const doc = {
    documentElement: {},
    head: { appendChild: (node) => children.push(node) },
    getElementById: () => null,
    createElement: () => ({ id: '', textContent: '' }),
  }
  hideOfficialRail(doc, class {
    observe() {}
    disconnect() {}
  })
  assert.equal(children[0].id, STYLE_ID)
  assert.equal(children[0].textContent, RAIL_CSS)
  assert.doesNotMatch(RAIL_CSS, /dsh-studio-native/)
  assert.match(RAIL_CSS, /!important/)
})
