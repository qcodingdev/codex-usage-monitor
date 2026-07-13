#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/Codex Usage Monitor.app"
export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD/module-cache"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/module-cache"
swiftc -swift-version 5 -parse-as-library -O \
  -framework AppKit \
  -framework Foundation \
  "$ROOT/Sources/CodexUsageMonitor.swift" \
  -o "$APP/Contents/MacOS/CodexUsageMonitor"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/Codex-Usage-Monitor-macOS.zip"

echo "$APP"
