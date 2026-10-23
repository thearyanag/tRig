#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
APP_EXECUTABLE="AccountWebTest"
BUNDLE="$ROOT_DIR/dist/tRig.app"
CHART_SOURCE="$ROOT_DIR/Sources/AccountWebTest/Workbench/Resources/Chart"
TV_LIBRARY="${TRIG_TRADINGVIEW_LIBRARY_PATH:-$ROOT_DIR/vendor/tradingview/charting_library}"

case "$MODE" in
  run|--verify|--build-only) ;;
  *) echo 'Usage: build_and_run.sh [run|--verify|--build-only]' >&2; exit 2 ;;
esac

for dependency in swift cargo codesign rsync; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Missing required tool: $dependency. See apps/macos/README.md." >&2
    exit 1
  fi
done

# Keep the running app available if compilation fails.
swift build
BIN_DIR="$(swift build --show-bin-path)"
cargo build --manifest-path "$ROOT_DIR/backend/trading-data/Cargo.toml" --locked
if [ "$MODE" != '--build-only' ]; then
  pkill -x "$APP_EXECUTABLE" >/dev/null 2>&1 || true
fi

mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Helpers" "$BUNDLE/Contents/Resources/Chart"
cp "$BIN_DIR/$APP_EXECUTABLE" "$BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
cp "$ROOT_DIR/backend/trading-data/target/debug/trading-data-service" "$BUNDLE/Contents/Helpers/trading-data-service"
codesign --force --sign - --entitlements "$ROOT_DIR/ChartHelper.entitlements" "$BUNDLE/Contents/Helpers/trading-data-service"
cp "$CHART_SOURCE/"* "$BUNDLE/Contents/Resources/Chart/"

if [ -f "$TV_LIBRARY/charting_library.standalone.js" ]; then
  mkdir -p "$BUNDLE/Contents/Resources/Chart/charting_library"
  rsync -a --delete "$TV_LIBRARY/" "$BUNDLE/Contents/Resources/Chart/charting_library/"
else
  # Remove only generated optional assets, never the user's library source.
  rm -rf "$BUNDLE/Contents/Resources/Chart/charting_library"
  echo 'Building without proprietary chart assets; search and research tools remain available.'
fi

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
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST

codesign --force --sign - --entitlements "$ROOT_DIR/SessionTest.entitlements" "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
if [ "$MODE" != '--build-only' ]; then /usr/bin/open -n "$BUNDLE"; fi
if [ "$MODE" = '--verify' ]; then
  sleep 1
  pgrep -x "$APP_EXECUTABLE" >/dev/null
fi
