#!/usr/bin/env bash
# Bring up the studio runtime and the native shell, from anywhere.
#
# Everything here is anchored to the repo, not to the shell's cwd, because the
# interesting failure is running this from some other checkout and watching
# relative paths resolve into nothing.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

DSH_VERSION="${DSH_VERSION:-0.1.0-rc.6}"
PORT="${PORT:-3081}"
export DSH_HOME="$REPO/.dsh-home"

APP_BINARY="$REPO/apps/macos/.build/bundle/DSH Studio.app/Contents/MacOS/dsh-studio"
LOG_DIR="$REPO/.dsh-home/logs"
mkdir -p "$LOG_DIR"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- is a studio runtime already answering on this port? -------------------
# Reusing a live runtime keeps iteration fast, but only if it is *our* profile.
# A stranger on 3081 would hand the shell a manifest it cannot honour, so we
# check for our client plugin rather than just the port.
#
# Note we probe the boot manifest, not /studio/surface: that endpoint wants a
# Bearer token and quietly falls through to the SPA's index.html without one,
# so it answers 200 with HTML even when nothing is wired up.
serves_studio() {
  curl -fsS --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null \
    | grep -q 'dsh-studio/studio-client'
}

if serves_studio "$PORT"; then
  say "reusing studio runtime already listening on 127.0.0.1:$PORT"
else
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $PORT is taken by something that is not a studio runtime." >&2
    echo "pick another one:  PORT=3082 $0" >&2
    exit 1
  fi

  say "building client + surface bundles"
  npm run bundle >"$LOG_DIR/bundle.log" 2>&1 \
    || { echo "bundle failed, see $LOG_DIR/bundle.log" >&2; exit 1; }

  say "materialising the studio profile into $DSH_HOME"
  node scripts/studio-home.mjs

  # `--profile studio` has to come before the port; the runtime treats a
  # trailing subcommand as a positional argument and bails with
  # "too many arguments".
  say "starting runtime on 127.0.0.1:$PORT"
  npx -y "@deepseek-ai/dsh@$DSH_VERSION" --profile studio --port "$PORT" \
    >"$LOG_DIR/runtime.log" 2>&1 &

  for _ in $(seq 1 60); do
    serves_studio "$PORT" && break
    sleep 0.5
  done

  serves_studio "$PORT" \
    || { echo "runtime never served /studio/surface, see $LOG_DIR/runtime.log" >&2; exit 1; }
  say "runtime up"
fi

# --- the native shell ------------------------------------------------------
if [[ ! -x "$APP_BINARY" ]]; then
  say "packaging DSH Studio.app"
  ( cd apps/macos && ./scripts/package-app.sh )
fi

# `open` drops the environment, so exec the binary inside the bundle directly.
# DSH_HOME matters: without it the shell cannot find bridge.json and silently
# falls back to its compiled-in manifest instead of the runtime's authority.
say "launching DSH Studio against 127.0.0.1:$PORT"
DSH_STUDIO_SHELL_URL="http://127.0.0.1:$PORT" exec "$APP_BINARY"
