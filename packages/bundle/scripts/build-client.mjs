#!/usr/bin/env node
/**
 * Builds the browser half of this dual-face package.
 *
 * The wire format is not ours to choose — `dsh-client-modules` serves
 * `/plugins/<id>/client.js` and the shell's module table expects each bundle to
 * register itself through `window.__ModuleLoader__.load({ id, factory })`,
 * receiving a `require` that resolves the shared runtime. Matching the shape
 * official client plugins already ship is the whole contract.
 *
 * Which packages stay external is the load-bearing part. The shared ones must
 * come through the injected `require`, because a second copy of React or of the
 * UI primitives inside our bundle would be a different module instance — the
 * same identity hazard that makes the host half import nothing at all, except
 * here it shows up as hooks failing or components silently not matching.
 *
 *   node scripts/build-client.mjs [--watch]
 */
import { build, context } from 'esbuild'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')
const id = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).name

/**
 * Resolved by the shell, never bundled. React and the primitives are the two
 * that would break loudly; every other `@deepseek-ai/dsh-client-*` is listed
 * because reaching one from a private copy is never what we mean.
 */
const shared = ['react', 'react-dom', 'react/jsx-runtime', 'react-dom/client']

const wrapper = {
  banner: {
    js: `window.__ModuleLoader__.load({\n\tid: ${JSON.stringify(id)},\n\tfactory: (require) => {\nvar module = { exports: {} };\nvar exports = module.exports;`,
  },
  footer: { js: 'return module.exports;\n\t}\n});' },
}

const options = {
  entryPoints: [join(root, 'src/client.jsx')],
  outfile: join(root, 'lib/client.js'),
  bundle: true,
  format: 'cjs',
  platform: 'browser',
  target: 'es2022',
  jsx: 'automatic',
  external: [...shared, '@deepseek-ai/*'],
  legalComments: 'none',
  ...wrapper,
}

if (process.argv.includes('--watch')) {
  const ctx = await context(options)
  await ctx.watch()
  console.log('watching src/client.jsx …')
} else {
  await build(options)
  const bytes = readFileSync(options.outfile).byteLength
  console.log(`client bundle  ${(bytes / 1024).toFixed(1)} KB  → lib/client.js`)
}
