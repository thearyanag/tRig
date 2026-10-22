#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
case "$MODE" in run|--verify|--build-only) ;; *) echo 'Usage: build_and_run.sh [run|--verify|--build-only]' >&2; exit 2;; esac
if [ "$MODE" != '--build-only' ]; then pkill -x AccountWebTest >/dev/null 2>&1 || true; fi
swift build
BIN_DIR="$(swift build --show-bin-path)"
BUNDLE="$ROOT_DIR/dist/tRig.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN_DIR/AccountWebTest" "$BUNDLE/Contents/MacOS/AccountWebTest"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AccountWebTest</string>
<key>CFBundleIdentifier</key><string>local.telemo.AccountWebTest</string>
<key>CFBundleName</key><string>tRig</string>
<key>CFBundleDisplayName</key><string>tRig</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$ROOT_DIR/SessionTest.entitlements" "$BUNDLE"
if [ "$MODE" != '--build-only' ]; then /usr/bin/open -n "$BUNDLE"; fi
if [ "$MODE" = '--verify' ]; then sleep 1; pgrep -x AccountWebTest >/dev/null; fi
