# dsh-studio plugin

Out-of-tree Cordis **bundle** for a `studio` profile. It does not fork DeepSeek Harness.

## What it does

- Exports `apply(ctx, config)` plus `name`, `inject`, and a Schemastery / Standard Schema `Config`.
- Starts a loopback JSON control server (`127.0.0.1:43180` by default) via `ctx.effect()`.
- Listens to `session/event` and remembers the last `turn/end` for `GET /status`.
- Serves and hot-swaps semantic theme packs (`GET/POST /theme`).
- Does **not** implement an agent loop and does **not** vendor dsh.

## Endpoints

| Method | Path | Body |
| --- | --- | --- |
| GET | `/health` | `{ ok, profile: "studio" }` |
| GET | `/status` | runtime + last turn (best-effort) |
| GET | `/theme` | current tokens + CSS variables |
| POST | `/theme` | `{ themeId?, appearance?, tokens? }` hot-swap |
| POST | `/notify-test` | `{ ok, lastTurn }` |

## Config

`bridgePort`, `bindHost`, `notifyOnTurnEnd`, `themeId`.

## Install into a profile

```sh
dsh plugin --profile studio add @deepseek-ai/dsh-web-app
dsh plugin --profile studio add ./plugin
dsh --profile studio
```

`prepare` compiles `src/index.ts` → `index.js` so git installs work. A prebuilt `index.js` is committed for `file:` installs without a build toolchain.
