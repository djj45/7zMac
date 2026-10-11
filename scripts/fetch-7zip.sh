#!/usr/bin/env bash
# 下载 7-Zip 官方源码并打上 7zMac 补丁
set -euo pipefail

# 本机私有配置（如代理），不提交到 Git：scripts/local.env
# 例：export https_proxy="http://127.0.0.1:20122"
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"

VER=26.04
TAG=2604
SHA256=9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/vendor"

TARBALL="7z${TAG}-src.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "==> 下载 7-Zip ${VER} 源码"
  curl -fL --retry 3 -o "$TARBALL.part" \
    "https://github.com/ip7z/7zip/releases/download/${VER}/${TARBALL}"
  mv "$TARBALL.part" "$TARBALL"
fi

echo "==> 校验 SHA-256"
echo "${SHA256}  ${TARBALL}" | shasum -a 256 -c -

echo "==> 解包"
rm -rf 7zip
mkdir 7zip
tar -xf "$TARBALL" -C 7zip

echo "==> 打补丁"
for p in "$ROOT"/vendor/patches/*.patch; do
  echo "    $(basename "$p")"
  patch -d 7zip -p1 --forward < "$p"
done

echo "==> 完成：vendor/7zip"
