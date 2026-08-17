/**
 * Build of `studio-client`: the node half (host loader row) plus the browser
 * bundle the BootManifest fetches. Layout and wrapper come from
 * `../tsdown.shared.ts`, which mirrors upstream's client preset.
 */

import { clientBundle } from '../tsdown.shared.ts'

export default clientBundle('@dsh-studio/studio-client', ['lib/types/index.js'])
