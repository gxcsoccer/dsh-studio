#!/usr/bin/env bash
# Wraps the built executable into a real .app bundle.
#
# Not cosmetics: a bare executable has no bundle identifier, and
# UNUserNotificationCenter traps rather than degrades when asked for one. Dock
# presence, the app menu, and the window's activation behaviour all come from
# here too — a SwiftUI window launched from a bare binary never takes focus
# properly.
#
# The build stays unsigned for now. Signing, notarization, and the Keychain
# provider that depends on a stable signing identity are a later milestone.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="DSH.app"
OUT=".build/${APP}"

swift build -c "$CONFIG" --product DSH

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/$CONFIG/DSH" "$OUT/Contents/MacOS/DSH"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DSH Studio</string>
  <key>CFBundleDisplayName</key><string>DSH Studio</string>
  <key>CFBundleIdentifier</key><string>com.gxcsoccer.dsh-studio</string>
  <key>CFBundleExecutable</key><string>DSH</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Not an agent: Studio owns a window and belongs in the Dock. -->
  <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough for the notification centre to accept a bundle
# identifier locally. It is NOT distribution signing.
codesign --force --sign - "$OUT" >/dev/null 2>&1 || echo "warn: ad-hoc 签名失败，通知可能不工作"

echo "built  $(pwd)/$OUT"
echo "run    open $(pwd)/$OUT"
