/**
 * Shared tsdown preset for the two Studio packages.
 *
 * It is a deliberately thin mirror of upstream's own preset
 * (`deepseek-harness/packages/client/tsdown.client.ts`), because the artifact it
 * produces is not ours to invent: `dsh-client-modules` resolves
 * `exports["./client"]` off the installed package, fetches that file as a
 * classic script, and expects it to register itself through
 * `window.__ModuleLoader__.load({ id, factory })` — a CJS factory whose
 * `require` is answered from the shell's frozen module table. A bundle that
 * misses any part of that handshake fails at boot with "bundle loaded without
 * registering …", which is exactly the failure a hand-rolled config produces.
 *
 * So the layout below is copied on purpose:
 *
 *   lib/index.js    node half (ESM) — the host loader row
 *   lib/client.js   browser half (CJS factory) — fetched through the BootManifest
 *   lib/types/      tsc's declarations *and* the JS both bundles are built from
 *
 * What we do NOT copy: the CSS-modules pipeline (Studio ships no stylesheet —
 * native views are SwiftUI) and the host/client build faces (two packages do not
 * need a phase split).
 */

import type { UserConfig } from 'tsdown'

/**
 * The shell's frozen module table, mirrored from
 * `@deepseek-ai/dsh-client-web/src/platform` (`PLATFORM_MODULES`) plus the
 * documented `runtime/client` exemption. These specifiers stay `external`: the
 * injected `require` answers them with the **shell's** instances, and inlining
 * a second copy of React or of `ui-slots` would give Studio a private slot
 * registry — i.e. a takeover that shadows nothing.
 */
export const CLIENT_EXTERNALS: readonly string[] = [
  'react', 'react/jsx-runtime', 'react-dom', 'react-dom/client',
  '@deepseek-ai/cordis',
  '@deepseek-ai/dsh-client-ui-slots',
  '@deepseek-ai/dsh-client-web-react',
  '@deepseek-ai/dsh-client-ui-primitives',
  '@deepseek-ai/dsh-client-ui-attachment',
  '@deepseek-ai/dsh-client-schema-form',
  '@deepseek-ai/dsh-client-runtime/client',
]

/**
 * Node-half library config: bundle the tsc output of one entry into `lib/`.
 * @param id - package name, for tsdown diagnostics.
 * @param entry - emitted entries under `lib/types`.
 * @param overrides - extra config merged last.
 * @returns the node-side config.
 */
export function nodeLibrary(id: string, entry: readonly string[], overrides: UserConfig = {}): UserConfig {
  return {
    name: id,
    entry: [...entry],
    outDir: 'lib',
    format: ['esm'],
    platform: 'node',
    target: 'es2024',
    fixedExtension: false,
    // Types come from tsc (lib/types), which is also what package.json points
    // `types` at; a second dts pass here would only be able to disagree.
    dts: false,
    clean: false,
    ...overrides,
  }
}

/**
 * Browser-half config: the `__ModuleLoader__` factory artifact.
 * @param id - package name; it is the handoff id the shell's module table keys on.
 * @param entry - the emitted client entry under `lib/types`.
 * @returns the browser-side config.
 */
export function browserBundle(id: string, entry: string): UserConfig {
  return {
    name: `${id}/client`,
    entry: { client: entry },
    // Lands next to the node half in the same lib/ directory, so `clean` must
    // stay off: a default clean would wipe the node output emitted above.
    outDir: 'lib',
    format: 'cjs',
    platform: 'browser',
    dts: false,
    // The bundle is fetched outside any bundler's module graph, so it has to
    // carry its own map for anything to be debuggable in the WKWebView.
    sourcemap: true,
    clean: false,
    external: [...CLIENT_EXTERNALS],
    define: {
      'process.env.NODE_ENV': JSON.stringify(process.env.NODE_ENV ?? 'production'),
    },
    // tsdown auto-externalizes declared dependencies; anything the frozen
    // module table cannot answer must be inlined instead, because a `require`
    // it cannot answer is a guaranteed runtime throw.
    noExternal: (specifier: string) => (CLIENT_EXTERNALS.includes(specifier) ? undefined : true),
    plugins: [{
      // Build-time mirror of the module-edge rule (upstream calls it the bundle
      // purity gate): a value import of another plugin either duplicates a
      // runtime instance or asks the table for a specifier it does not hold.
      // Type-only imports are erased before this hook ever sees them, which is
      // why `upstream.ts` may name half the client tree.
      name: 'studio-client-bundle-purity',
      resolveId(specifier: string) {
        if (!specifier.startsWith('@deepseek-ai/')) return null
        if (CLIENT_EXTERNALS.includes(specifier)) return null
        throw new Error(
          `studio bundle purity: "${specifier}" is not in the shell module table (CLIENT_EXTERNALS) — `
          + 'cross-plugin value imports are forbidden; collaborate through cordis services '
          + '(a type-only import would have been erased before this gate)',
        )
      },
    }],
    outputOptions: {
      // The route is /plugins/<package>/client.js: the name is part of the
      // contract, not a preference.
      entryFileNames: 'client.js',
      banner: `window.__ModuleLoader__.load({ id: ${JSON.stringify(id)}, factory: (require) => {`,
      footer: 'return module.exports; } });',
      intro: 'var module = { exports: {} }; var exports = module.exports;',
    },
  }
}

/**
 * Both halves of a dual-face client package.
 * @param id - package name.
 * @param nodeEntry - emitted node entries under `lib/types`.
 * @param clientEntry - emitted browser entry under `lib/types`.
 * @returns the configs tsdown runs, node half first.
 */
export function clientBundle(
  id: string,
  nodeEntry: readonly string[],
  clientEntry = 'lib/types/client/index.js',
): UserConfig[] {
  return [nodeLibrary(id, nodeEntry), browserBundle(id, clientEntry)]
}
