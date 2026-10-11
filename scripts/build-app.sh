#!/usr/bin/env bash
# 一键构建并安装 7zMac：
#   7zz（如未编译）→ xcodegen → xcodebuild → 安装到 /Applications → 注册 Finder 扩展
# 只构建不安装（打包 DMG / CI 用）：NO_INSTALL=1 bash scripts/build-app.sh
set -euo pipefail

# 本机私有配置（如代理），不提交到 Git：scripts/local.env
# 例：export https_proxy="http://127.0.0.1:20122"
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------- 0. 环境检查 ----------
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ 没有找到完整 Xcode。请从 App Store 安装 Xcode，然后执行："
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi
export PATH="$ROOT/vendor/tools/xcodegen/bin:$PATH"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> 安装 xcodegen"
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    mkdir -p vendor/tools
    curl -fL --retry 3 -o vendor/tools/xcodegen.zip \
      https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
    (cd vendor/tools && unzip -q -o xcodegen.zip)
  fi
fi

# ---------- 1. 7zz ----------
if [ ! -x vendor/bin/7zz ] || [ "${REBUILD_7ZZ:-0}" = "1" ]; then
  bash scripts/build-7zz.sh
fi

# ---------- 2. 签名身份 ----------
# 优先使用 “Apple Development” 证书（Xcode › 设置 › 账户 登录 Apple ID 后自动生成）。
# Finder 扩展在 ad-hoc 签名下经常不被系统加载，所以强烈建议有证书。
SIGN_ID="-"
TEAM=""

find_dev_identity() {
  # 输出形如：  1) 0123ABCD...  "Apple Development: 名字 (XXXXXXXXXX)"
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ { print $2; exit }' || true
}

HASH="$(find_dev_identity)"
if [ -z "$HASH" ] && security find-identity -p codesigning 2>/dev/null | grep "Apple Development" >/dev/null; then
  # 证书在钥匙串里，但缺少苹果中间证书（WWDR G3）导致“不受信任”——自动补装
  echo "==> 证书不受信任，安装 Apple WWDR G3 中间证书"
  TMP_CER="$(mktemp -t AppleWWDRCAG3).cer"
  if curl -fsSL -o "$TMP_CER" https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer; then
    security import "$TMP_CER" -k "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
  fi
  rm -f "$TMP_CER"
  HASH="$(find_dev_identity)"
fi

if [ -n "$HASH" ]; then
  SIGN_ID="$HASH"
  TEAM="$( (security find-certificate -a -Z -c "Apple Development" -p 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1) || true )"
  echo "==> 签名：Apple Development（${HASH:0:8}…，Team ${TEAM:-未知}）"
else
  echo "⚠️  没有找到可用的 Apple Development 证书，改用 ad-hoc 签名。"
  echo "   钥匙串里的签名身份："
  security find-identity -p codesigning 2>/dev/null | sed 's/^/     /' || true
fi

# ---------- 3. 生成工程并编译 ----------
echo "==> xcodegen"
xcodegen generate --quiet

echo "==> xcodebuild"
mkdir -p build
BUILD_ARGS=(
  -project 7zMac.xcodeproj
  -scheme SevenZipMac
  -configuration Release
  -derivedDataPath build
  -destination 'generic/platform=macOS'
  CODE_SIGN_STYLE=Manual
  "CODE_SIGN_IDENTITY=${SIGN_ID}"
  PROVISIONING_PROFILE_SPECIFIER=
)
[ -n "$TEAM" ] && BUILD_ARGS+=("DEVELOPMENT_TEAM=${TEAM}")

set -o pipefail
if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild "${BUILD_ARGS[@]}" build | xcbeautify
else
  xcodebuild "${BUILD_ARGS[@]}" build 2>&1 | tee build/xcodebuild.log \
    | grep -E "error:|warning: .*(Swift|swift)|BUILD (SUCCEEDED|FAILED)" || true
  grep -q "BUILD SUCCEEDED" build/xcodebuild.log || { echo "✗ 构建失败，完整日志：build/xcodebuild.log"; exit 1; }
fi

APP="build/Build/Products/Release/7zMac.app"
codesign --verify --deep --strict "$APP"

if [ "${NO_INSTALL:-0}" = "1" ]; then
  echo "✓ 已构建 ${APP}（未安装）"
  exit 0
fi

# ---------- 4. 安装 ----------
echo "==> 安装到 /Applications"
pkill -x 7zMac 2>/dev/null || true
rm -rf /Applications/7zMac.app
cp -R "$APP" /Applications/

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# 构建目录里的那份 App 也会被系统登记，导致右键出现两个「压缩」——注销并删掉它，只保留 /Applications 里的
pluginkit -r "$ROOT/$APP/Contents/PlugIns/SevenZipFinder.appex" 2>/dev/null || true
"$LSREGISTER" -u "$ROOT/$APP" 2>/dev/null || true
rm -rf "$ROOT/$APP"
"$LSREGISTER" -f /Applications/7zMac.app

# 注册扩展（不启动主程序，避免弹出设置窗口）
pluginkit -a /Applications/7zMac.app/Contents/PlugIns/SevenZipFinder.appex 2>/dev/null || true
pluginkit -e use -i local.djj45.7zmac.finder 2>/dev/null || true
killall Finder 2>/dev/null || true

echo
echo "✓ 已安装 /Applications/7zMac.app"
echo "  若右键没有「压缩」「解压」：系统设置 › 通用 › 登录项与扩展 › 访达（Finder）扩展 中勾选 7zMac"
pluginkit -m -i local.djj45.7zmac.finder || true
