#!/usr/bin/env bash
#
# 把 SwiftPM 的可执行产物组装成一个真正的 macOS app bundle。
#
# 为什么是手工组装而不是 .xcodeproj：
#   - 依赖方向是本项目最重要的架构不变量（ADR-0002），而它由 Package.swift
#     的 target 图 + 源码扫描测试共同守着。引入 Xcode 工程等于把这张图复制
#     一份到一个不会被 `swift test` 检查的地方，两份迟早不一致。
#   - .xcodeproj 是二进制式的 XML，review 时看不出「谁又依赖了 WebKit」。
#   - W8 要删掉 WebView 那两个文件；SwiftPM + 这个脚本删完即生效，
#     Xcode 工程还要再改一遍 build phase。
#
# 用法：
#   scripts/package-app.sh                     # release 打包
#   scripts/package-app.sh --debug             # debug 打包（带符号，跑得快）
#   scripts/package-app.sh --open              # 打包后直接启动
#   scripts/package-app.sh --output /tmp/out   # 指定输出目录
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="release"
OUTPUT_DIR="$PACKAGE_ROOT/.build/bundle"
SIGN_IDENTITY="-"     # 默认 ad-hoc 签名：本机 dogfood 够用，也让 bundle id 生效
OPEN_AFTER=0
PRODUCT="dsh-studio"
APP_NAME="DSH Studio"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--debug) CONFIGURATION="debug"; shift ;;
		--release) CONFIGURATION="release"; shift ;;
		--output) OUTPUT_DIR="$2"; shift 2 ;;
		--sign) SIGN_IDENTITY="$2"; shift 2 ;;
		--open) OPEN_AFTER=1; shift ;;
		-h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "unknown flag: $1" >&2; exit 2 ;;
	esac
done

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "==> swift build -c $CONFIGURATION --product $PRODUCT"
cd "$PACKAGE_ROOT"
swift build -c "$CONFIGURATION" --product "$PRODUCT"
BINARY="$(swift build -c "$CONFIGURATION" --product "$PRODUCT" --show-bin-path)/$PRODUCT"
[[ -x "$BINARY" ]] || { echo "built binary missing at $BINARY" >&2; exit 1; }

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/$PRODUCT"
cp "$PACKAGE_ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
# CFBundlePackageType + CFBundleSignature 的二进制回声。老，但 Finder 仍在看它。
printf 'APPL????' > "$CONTENTS/PkgInfo"

# 构建号带上 git 描述：dogfood 时「我到底在跑哪一版」必须一眼可答。
BUILD_ID="$(git -C "$PACKAGE_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
BUILD_COUNT="$(git -C "$PACKAGE_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_COUNT" "$CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :DSHStudioSourceRevision string $BUILD_ID" "$CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :DSHStudioConfiguration string $CONFIGURATION" "$CONTENTS/Info.plist" >/dev/null

echo "==> plutil -lint"
plutil -lint "$CONTENTS/Info.plist"

echo "==> codesign (identity: $SIGN_IDENTITY)"
# 没签名的 bundle 拿不到稳定的 keychain / 通知身份；ad-hoc 已经够本机使用。
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_BUNDLE"
codesign --display --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist")"
echo "==> done: $APP_BUNDLE"
echo "    bundle id : $BUNDLE_ID"
echo "    version   : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist") ($BUILD_COUNT, $BUILD_ID)"
echo "    binary    : $(du -h "$CONTENTS/MacOS/$PRODUCT" | cut -f1)"

if [[ "$OPEN_AFTER" == "1" ]]; then
	echo "==> open"
	open "$APP_BUNDLE"
fi
