#!/usr/bin/env bash
# The full verification chain, in the order that makes a failure readable.
#
# Each layer catches something the others cannot, so running them in this order
# means the first thing that fails is also the most specific description of what
# broke. See ARCHITECTURE §6.
#
#   1. codegen   — the contract's own schemas still map onto the method table
#   2. build     — the generated types still satisfy every call site
#   3. bundle    — the browser half's logic, and that its artifact is current
#   4. tests     — recorded real traffic still decodes into named branches
#   5. probe     — a live host still behaves the way the types say (opt-in:
#                  needs a running runtime, and spends real model tokens)
#
#   ./check.sh            # 1–4
#   ./check.sh --live     # 1–5
set -euo pipefail
cd "$(dirname "$0")"

step() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }

step "codegen（上游字段变了会在这里或下一步炸）"
node tools/schema-codegen/generate.mjs

step "build（生成的类型 vs 调用点）"
if ! git diff --quiet -- app/Sources/DSHKit/Generated 2>/dev/null; then
  echo "注意：codegen 产物有改动，说明上游契约动过了 —— 记得连同代码一起提交"
fi
swift build --package-path app

step "bundle（浏览器半边：判定逻辑 + 产物）"
npm --prefix packages/bundle test --silent
node packages/bundle/scripts/build-client.mjs
if ! git diff --quiet -- packages/bundle/lib 2>/dev/null; then
  echo "注意：client 产物有改动 —— 记得连同源码一起提交"
fi

step "test（录制的真实下行流）"
swift test --package-path app

if [[ "${1:-}" == "--live" ]]; then
  step "probe（对真实运行时）"
  app/.build/debug/dsh-probe supervised --cwd "${HOME}"
fi

printf '\n\033[1;32mall good\033[0m\n'
