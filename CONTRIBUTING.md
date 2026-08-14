# Contributing

DSH Studio is a bundle plus a native host on official `dsh`. It is not a fork of DeepSeek Harness.

先读 [README.md](./README.md)、[ARCHITECTURE.md](./ARCHITECTURE.md)、[docs/product.md](./docs/product.md)。

## Do not

- Do not clone or vendor [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness). Runtime comes from official `dsh`.
- Do not treat an upstream PR as a prerequisite for desktop work. Official docs already say UI is a plugin.
- Do not start from Electron or iframe the official Web UI.
- Do not depend on unpublished APIs. Published seams: `apply`, `inject`, `Config` / Schemastery, `ctx.effect`, `session/event`, `ctx.agents` (and `agent.inject()` as documented for model-facing context).
- Do not commit `.dsh/`, keychain material, or real session logs.

## Plugin-first PRs

Welcome, in this order:

1. Bundle / profile — `studio` stack, `dsh.bundle` patch, `apply` lifecycle, loopback bridge.
2. Native surface — SwiftUI first; later Tauri on the same bridge (windowing, keychain, notifications, file dialogs, workspace + session).
3. Making "everything is a plugin" usable — plugin manager UI, first-run, empty states, a11y.
4. Docs that track upstream breaking changes.

Keep implementation PRs small. Name the official `dsh` version you tested (developer preview will break).

## Local

Official `dsh` must already run on your machine ([deepseek.com/harness](https://deepseek.com/harness)). This repo does not need an upstream clone. Mac host needs recent Xcode; the bundle needs the Node version official `dsh` requires.

Contributions are MIT. Repository copyright: 2026 gxcsoccer.
