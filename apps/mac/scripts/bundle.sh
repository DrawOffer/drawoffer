#!/usr/bin/env bash
# Build a runnable DrawOffer.app for local runs: URL scheme callbacks (drawoffer://)
# only reach a registered app bundle, not a bare `swift run` binary.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
bash scripts/swift.sh build --product DrawOffer -c "$CONFIG"
BIN="$(bash scripts/swift.sh build --product DrawOffer -c "$CONFIG" --show-bin-path)"
APP=".build/DrawOffer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DrawOffer" "$APP/Contents/MacOS/DrawOffer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/DrawOffer.icns "$APP/Contents/Resources/DrawOffer.icns"
for bundle in "$BIN"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
# 本机语音识别（macOS 26 以下）用的 sherpa-onnx 动态库：先跑 scripts/fetch-sherpa.sh；没有就跳过，只退回云端识别。
if [ -f Vendor/sherpa-onnx/libsherpa-onnx-c-api.dylib ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp Vendor/sherpa-onnx/*.dylib "$APP/Contents/Frameworks/"
  for lib in "$APP/Contents/Frameworks/"*.dylib; do codesign --force --sign - "$lib" >/dev/null 2>&1 || true; done
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "$PWD/$APP"
