/**
 * Local type shims for the upstream `deepseek-harness` **host** packages.
 *
 * Same rationale as `studio-client/src/types/shims.d.ts`: the upstream
 * packages are not installable from this subtree, so the surface Studio
 * touches is transcribed here, narrowed, and cited. Two rules keep this
 * honest:
 *
 *  1. Nothing is invented. Each block names the upstream file it came from.
 *  2. Everything declared here is imported **as a type** by the source, with
 *     one deliberate exception — `toFetchHandler`, a value. It is used only in
 *     `src/index.ts`, the composition root, which is therefore typechecked but
 *     never executed by the test suite (the tests drive `bridge-server.ts`
 *     through its `upstream` seam instead). That boundary is what lets a
 *     subtree with zero upstream packages installed still typecheck and still
 *     have executable tests.
 *
 * The `@deepseek-ai/cordis` module itself is declared by the client package's
 * shim (one owner per module). Upstream adds `ctx.apiProxy` and
 * `ctx.dshHomePath` onto `Context` by declaration merging; merging them back in
 * *here* would push host-only members onto the client's `Context` too (one
 * tsconfig program, one merged interface), so the host face is expressed as a
 * plain extension in `src/host-context.ts` instead.
 */

declare module '@deepseek-ai/dsh-host-apiproxy' {
  /**
   * packages/host/apiproxy/src/api/index.ts — opaque here on purpose. The
   * data channel never reads a member off it: it hands the whole gateway to
   * {@link toFetchHandler} and forwards HTTP. Any narrowing beyond opacity
   * would be Studio re-modelling the domain, which ADR-0002 forbids.
   */
  export interface ApiProxy {
    readonly __apiProxy?: unique symbol
  }

  /**
   * packages/host/apiproxy/src/fetch/handler.ts — wraps the gateway into a
   * pure `Request → Response` function. `POST /api/<method>` takes a
   * `client-request` envelope; `GET /api/events.mux` is the SSE stream.
   * @param api - the host-side gateway.
   * @returns an object holding a fetch-compatible function.
   */
  export function toFetchHandler(api: ApiProxy): { fetch: typeof fetch }
}
