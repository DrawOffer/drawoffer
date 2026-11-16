#!/usr/bin/env bash
# 下载 sherpa-onnx 预编译动态库（universal2，Apache-2.0）到 Vendor/sherpa-onnx，供 bundle.sh 打进 App。
# 版本与 Sources/CSherpaOnnx/vendor/c-api.h 一致；升级时两边一起换，并更新这里的 sha256。
# 没有这些库时 App 照常构建运行，只是 macOS 26 以下不能本机识别（退回云端）。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="v2.0.1"
NAME="sherpa-onnx-${VERSION}-osx-universal2-shared-no-tts-lib"
SHA256="242b0593a033456e9344a76a11713d1c55da794d0e37eabf6acabaf7beeb2b36"
DEST="Vendor/sherpa-onnx"
if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ]; then
  echo "$DEST 已是 $VERSION"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/lib.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${NAME}.tar.bz2"
echo "${SHA256}  $TMP/lib.tar.bz2" | shasum -a 256 -c - >/dev/null
tar -xjf "$TMP/lib.tar.bz2" -C "$TMP"
rm -rf "$DEST"; mkdir -p "$DEST"
cp "$TMP/$NAME/lib/libsherpa-onnx-c-api.dylib" "$TMP/$NAME/lib/libonnxruntime.dylib" "$DEST/"
echo "$VERSION" > "$DEST/.version"
echo "已下载到 $DEST"
