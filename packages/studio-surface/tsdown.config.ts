/**
 * Build of `studio-surface`: a host-only plugin, so there is no browser half.
 *
 * `@dsh-studio/studio-client` is inlined rather than externalized: the only
 * thing this package imports from it is the wire contract (`PROTOCOL_VERSION`
 * and types), and a runtime dependency on a sibling package would force the
 * profile install to resolve a second package for one integer.
 */

import { nodeLibrary } from '../tsdown.shared.ts'

export default nodeLibrary('@dsh-studio/studio-surface', ['lib/types/index.js'])
