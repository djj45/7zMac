#!/usr/bin/env bash
# 构建 7zMac 并打包成 DMG：dist/7zMac-<版本>.dmg
# 用法：bash scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NO_INSTALL=1 bash scripts/build-app.sh

APP="build/Build/Products/Release/7zMac.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/7zMac-${VERSION}.dmg"

echo "==> 打包 $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$DMG"
hdiutil create -quiet -volname "7zMac ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

# 用和 App 相同的身份给 DMG 签名（ad-hoc 构建则跳过）
SIGN_ID="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)$/\1/p' | head -1 || true)"
if [ -n "$SIGN_ID" ]; then
  codesign --force --sign "$SIGN_ID" "$DMG" || true
fi

shasum -a 256 "$DMG"
echo "✓ $DMG"
