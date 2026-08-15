# schema-codegen

Generates the Swift face of the DeepSeek Harness wire contract from the official
zod schemas.

```sh
node generate.mjs                       # → ../../app/Sources/DSHKit/Generated/
node generate.mjs --from <node_modules> --out <dir>
```

## Why generate

The gateway protocol carries no version negotiation, and nothing on the wire
even reports the contract version — `host.describe().version` is the host app's
(`apps/cli`) package version, which does not track
`@deepseek-ai/dsh-host-apiproxy`. Hand-written Swift types would drift silently.
Generated ones turn an upstream field change into a compile error.

See [ARCHITECTURE §6](../../ARCHITECTURE.md#6-跟住一个没有版本号的上游).

## Where the contract comes from

The machine's own Harness profile (`$DSH_HOME/profiles/node_modules`), not a
copy vendored here. Codegen must describe the runtime that actually boots; a
second copy in this repo could drift from the profile and nobody would notice.
Nothing needs installing — both `zod` and the contract resolve out of the
profile.

## The assertion that matters most

`RpcMethodMap` is read from `rpc-map.d.ts`, and every method must resolve to a
`<stem>RequestSchema` + `<stem>ValueSchema` pair. That pairing is a **naming
convention, not a contract** — upstream's own method→schema table
(`UNARY_VALUE_SCHEMAS`) is module-private. If a rename breaks the convention,
codegen exits non-zero and names the methods it lost, rather than quietly
emitting a smaller API.

## What it does and does not cover

| | |
| --- | --- |
| Covered | RPC request/response payloads, `MuxFrame` / `HostFrame`, envelopes — 158 schemas |
| Not covered | `SessionEvent.data`. It is `z.unknown()` on purpose: event payload types live in `SessionEventMap`, extended by declaration merging across 22 packages. Those arrive as `JSONValue`. |

## Two decisions worth knowing

**Unknown fields break the build; unknown enum cases do not.** Every closed set
gets a `.unknown` case, because the contract is merge-extensible by design — a
plugin adding a tool kind must not crash the client.

**Request and response types are nominal, everything else dedups.** No `$defs`
means shapes are inlined and repeat, so structurally identical types are
collapsed. Method types are exempt: `session.cancel` and `session.models` both
take `{ sessionId }`, and collapsing them would make it impossible to give each
its own `WireRequest.Response`.

## Known gaps

- **Brands are lost.** `SessionId` and friends are `z.string()` plus a cast, so
  JSON Schema sees a plain string. Swift gets `String`. The brand schemas are
  systematically named, so a post-processing pass could restore newtypes.
- `survey.mjs` / `survey-unions.mjs` report which JSON Schema constructs and
  union shapes upstream actually uses. Run them after a version bump: a new
  construct shows up there before it shows up as bad Swift.
