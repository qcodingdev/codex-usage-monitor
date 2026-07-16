#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/Codex Usage Monitor.app"
X86_CACHE="$BUILD/module-cache/x86_64"
ARM_CACHE="$BUILD/module-cache/arm64"
X86_BINARY="$BUILD/CodexUsageMonitor.x86_64"
ARM_BINARY="$BUILD/CodexUsageMonitor.arm64"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$X86_CACHE" "$ARM_CACHE"
CLANG_MODULE_CACHE_PATH="$X86_CACHE" SWIFT_MODULECACHE_PATH="$X86_CACHE" \
swiftc -swift-version 5 -parse-as-library -O -target x86_64-apple-macos13.0 \
  -framework AppKit \
  -framework Foundation \
  "$ROOT/Sources/CodexUsageMonitor.swift" \
  -o "$X86_BINARY"
CLANG_MODULE_CACHE_PATH="$ARM_CACHE" SWIFT_MODULECACHE_PATH="$ARM_CACHE" \
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework Foundation \
  "$ROOT/Sources/CodexUsageMonitor.swift" \
  -o "$ARM_BINARY"
lipo -create "$X86_BINARY" "$ARM_BINARY" -output "$APP/Contents/MacOS/CodexUsageMonitor"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

PACKAGE_ROOT="$(mktemp -d "$BUILD/release.XXXXXX")"
PACKAGE="$PACKAGE_ROOT/Codex Usage Monitor macOS"
mkdir -p "$PACKAGE"
ditto "$APP" "$PACKAGE/Codex Usage Monitor.app"
cp "$ROOT/install-macos.command" "$PACKAGE/Install Codex Usage Monitor.command"
cp "$ROOT/codex-usage-monitor" "$PACKAGE/codex-usage-monitor"
chmod +x "$PACKAGE/Install Codex Usage Monitor.command" "$PACKAGE/codex-usage-monitor"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE" "$BUILD/Codex-Usage-Monitor-macOS.zip"

echo "$APP"
