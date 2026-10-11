#!/usr/bin/env bash
# 编译 7zz（arm64 + x86_64），合并为 Universal 二进制 vendor/bin/7zz
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/7zip/CPP/7zip/Bundles/Alone2"
[ -d "$SRC" ] || bash "$ROOT/scripts/fetch-7zip.sh"

JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=13.0

# 7-Zip 的 mac makefile 默认 -Weverything -Werror；新版 Xcode 的 clang 可能新增警告导致失败，
# 这里改成普通 -Wall，不把警告当错误。
WARN_OVERRIDES=(CFLAGS_WARN_WALL=-Wall CFLAGS_WARN=-Wno-everything)

cd "$SRC"
echo "==> 编译 arm64"
make -j"$JOBS" -f ../../cmpl_mac_arm64.mak MY_LIBS=-liconv "${WARN_OVERRIDES[@]}" >/dev/null
echo "==> 编译 x86_64"
make -j"$JOBS" -f ../../cmpl_mac_x64.mak MY_LIBS=-liconv "${WARN_OVERRIDES[@]}" >/dev/null

mkdir -p "$ROOT/vendor/bin"
lipo -create b/m_arm64/7zz b/m_x64/7zz -output "$ROOT/vendor/bin/7zz"
chmod +x "$ROOT/vendor/bin/7zz"

echo "==> 产物"
lipo -info "$ROOT/vendor/bin/7zz"
"$ROOT/vendor/bin/7zz" | head -3
