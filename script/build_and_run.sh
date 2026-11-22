#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TradingWorkspace"
BUNDLE_ID="com.aryan.TradingWorkspace"
MIN_SYSTEM_VERSION="14.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build --product "$APP_NAME"
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
cargo build --manifest-path "$ROOT_DIR/backend/trading-data/Cargo.toml" --locked

mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY.new"
mv -f "$APP_BINARY.new" "$APP_BINARY"
chmod +x "$APP_BINARY"
mkdir -p "$APP_BUNDLE/Contents/Resources/Icons"
rsync -a --delete "$ROOT_DIR/Sources/TradingWorkspace/Resources/Icons/" "$APP_BUNDLE/Contents/Resources/Icons/"
mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
rsync -a --delete "$ROOT_DIR/Sources/TradingWorkspace/Resources/Fonts/" "$APP_BUNDLE/Contents/Resources/Fonts/"
mkdir -p "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources/Chart/charting_library"
cp "$ROOT_DIR/backend/trading-data/target/debug/trading-data-service" "$APP_BUNDLE/Contents/Helpers/trading-data-service.new"
mv -f "$APP_BUNDLE/Contents/Helpers/trading-data-service.new" "$APP_BUNDLE/Contents/Helpers/trading-data-service"
chmod +x "$APP_BUNDLE/Contents/Helpers/trading-data-service"
cp "$ROOT_DIR/Sources/TradingWorkspace/Resources/Chart/"*.html "$APP_BUNDLE/Contents/Resources/Chart/"
cp "$ROOT_DIR/Sources/TradingWorkspace/Resources/Chart/"*.js "$APP_BUNDLE/Contents/Resources/Chart/"
cp "$ROOT_DIR/Sources/TradingWorkspace/Resources/Chart/"*.css "$APP_BUNDLE/Contents/Resources/Chart/"
rsync -a --delete "$ROOT_DIR/vendor/tradingview/charting_library/" "$APP_BUNDLE/Contents/Resources/Chart/charting_library/"
mkdir -p "$APP_BUNDLE/Contents/Resources/Chart/fonts"
cp "$ROOT_DIR/Sources/TradingWorkspace/Resources/Fonts/AlloVariable.woff2" "$APP_BUNDLE/Contents/Resources/Chart/fonts/"
cp "$ROOT_DIR/Sources/TradingWorkspace/Resources/Fonts/OFL.txt" "$APP_BUNDLE/Contents/Resources/Chart/fonts/"

TDLIB_BUILD="$ROOT_DIR/.build/telegram/tdlib-$(uname -m)"
if [[ -f "$TDLIB_BUILD/libtdjson.dylib" && -f "$TDLIB_BUILD/bundled-revision" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Frameworks"
  cp -L "$TDLIB_BUILD/libtdjson.dylib" "$APP_BUNDLE/Contents/Frameworks/libtdjson.dylib.new"
  mv -f "$APP_BUNDLE/Contents/Frameworks/libtdjson.dylib.new" "$APP_BUNDLE/Contents/Frameworks/libtdjson.dylib"
  cp "$TDLIB_BUILD/TDLib-LICENSE.txt" "$TDLIB_BUILD/OpenSSL-LICENSE.txt" "$APP_BUNDLE/Contents/Resources/"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Trading Workspace</string>
  <key>CFBundleDisplayName</key><string>Trading Workspace</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }

case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "Launched $APP_BUNDLE"
    ;;
esac
