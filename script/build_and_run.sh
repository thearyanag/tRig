#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TradingWorkspace"
BUNDLE_ID="com.aryan.TradingWorkspace"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="0.1.1"
BUILD_NUMBER="2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
BUILD_CONFIGURATION=debug
if [[ "$MODE" == "--bundle-release" ]]; then
  if [[ $# != 2 || "$2" != /*.app || -e "$2" ]]; then
    echo "usage: $0 --bundle-release /absolute/path/to/new.app" >&2
    exit 2
  fi
  APP_BUNDLE="$2"
  BUILD_CONFIGURATION=release
  export MACOSX_DEPLOYMENT_TARGET="$MIN_SYSTEM_VERSION"
fi
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
WIDGET_NAME="PortfolioPulseWidget"
WIDGET_BUNDLE="$APP_BUNDLE/Contents/PlugIns/$WIDGET_NAME.appex"
TDLIB_BUILD="$ROOT_DIR/.build/telegram/tdlib-$(uname -m)"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--bundle-release) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--bundle-release <new.app>]" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"
SWIFT_BUILD_ARGS=(--configuration "$BUILD_CONFIGURATION")
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  TELEGRAM_CONFIG="${TRIG_TELEGRAM_RELEASE_CONFIG:-$HOME/Library/Application Support/$BUNDLE_ID/telegram-release.json}"
  if [[ ! -f "$TELEGRAM_CONFIG" || ! -r "$TELEGRAM_CONFIG" ]]; then
    echo 'Set TRIG_TELEGRAM_RELEASE_CONFIG to a private JSON file with the dedicated tRig Telegram API credentials.' >&2
    echo "Default path: $HOME/Library/Application Support/$BUNDLE_ID/telegram-release.json" >&2
    exit 1
  fi
  if [[ ! -f "$TDLIB_BUILD/bundled-revision" || ! -f "$TDLIB_BUILD/libtdjson.dylib" ]]; then
    echo 'Run ./script/build_tdlib.sh before building the Telegram-enabled release.' >&2
    exit 1
  fi
  RELEASE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/trig-release.XXXXXX")"
  trap 'rm -rf -- "$RELEASE_WORK"' EXIT
  # Pass a private file path to the linker and embed only the two recognized fields.
  python3 - "$TELEGRAM_CONFIG" "$RELEASE_WORK/telegram.json" <<'PY'
import json
import os
import re
import sys

try:
    with open(sys.argv[1], "rb") as source:
        raw = source.read(4097)
    if len(raw) > 4096:
        raise ValueError
    credentials = json.loads(raw)
    if not isinstance(credentials, dict):
        raise ValueError
    api_id = credentials.get("api_id")
    api_hash = credentials.get("api_hash")
    if type(api_id) is not int or not 0 < api_id <= 2_147_483_647:
        raise ValueError
    if not isinstance(api_hash, str) or not re.fullmatch(r"[0-9a-fA-F]{32}", api_hash):
        raise ValueError
    os.umask(0o077)
    with open(sys.argv[2], "x") as embedded:
        json.dump({"api_id": api_id, "api_hash": api_hash}, embedded)
except (OSError, ValueError, RecursionError):
    sys.exit("Invalid Telegram release configuration. Expected a positive API ID and 32-digit hex API hash.")
PY
  SWIFT_BUILD_ARGS+=(
    --scratch-path "$RELEASE_WORK/swift-build"
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __trig_tg -Xlinker "$RELEASE_WORK/telegram.json"
  )
fi
npm ci --prefix "$ROOT_DIR/chart-host" --no-audit --no-fund --prefer-offline
npm run --prefix "$ROOT_DIR/chart-host" build
swift build "${SWIFT_BUILD_ARGS[@]}" --product "$APP_NAME"
BUILD_BINARY="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"
# The widget has its own link step and never receives the app's Telegram linker inputs.
swift build --configuration "$BUILD_CONFIGURATION" --product "$WIDGET_NAME"
WIDGET_BINARY="$(swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)/$WIDGET_NAME"
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  cargo build --manifest-path "$ROOT_DIR/backend/trading-data/Cargo.toml" --locked --release
else
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  "$ROOT_DIR/script/data_service.sh" sync-chart
fi

mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY.new"
mv -f "$APP_BINARY.new" "$APP_BINARY"
chmod +x "$APP_BINARY"
mkdir -p "$APP_BUNDLE/Contents/Resources/Icons"
rsync -a --delete "$ROOT_DIR/Sources/TradingWorkspace/Resources/Icons/" "$APP_BUNDLE/Contents/Resources/Icons/"
mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
rsync -a --delete "$ROOT_DIR/Sources/TradingWorkspace/Resources/Fonts/" "$APP_BUNDLE/Contents/Resources/Fonts/"
mkdir -p "$APP_BUNDLE/Contents/Resources/Onboarding"
rsync -a --delete "$ROOT_DIR/Sources/TradingWorkspace/Resources/Onboarding/" "$APP_BUNDLE/Contents/Resources/Onboarding/"
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources/Chart"
  install -m 755 "$ROOT_DIR/backend/trading-data/target/release/trading-data-service" \
    "$APP_BUNDLE/Contents/Helpers/trading-data-service"
  rsync -a --delete "$ROOT_DIR/.build/chart-host/" "$APP_BUNDLE/Contents/Resources/Chart/"
else
  rm -f -- "$APP_BUNDLE/Contents/Helpers/trading-data-service"
fi

mkdir -p "$WIDGET_BUNDLE/Contents/MacOS" "$WIDGET_BUNDLE/Contents/Resources"
cp "$WIDGET_BINARY" "$WIDGET_BUNDLE/Contents/MacOS/$WIDGET_NAME.new"
mv -f "$WIDGET_BUNDLE/Contents/MacOS/$WIDGET_NAME.new" "$WIDGET_BUNDLE/Contents/MacOS/$WIDGET_NAME"
for icon in solana.jpg backpack.png usdc.png; do
  cp "$ROOT_DIR/Sources/TradingWorkspace/Resources/Icons/$icon" "$WIDGET_BUNDLE/Contents/Resources/"
done
cat > "$WIDGET_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$WIDGET_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.$WIDGET_NAME</string>
  <key>CFBundleName</key><string>Portfolio Pulse</string>
  <key>CFBundleDisplayName</key><string>Portfolio Pulse</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>DTPlatformName</key><string>macosx</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

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
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>trig</string></array>
  </dict></array>
</dict>
</plist>
PLIST

if [[ "$BUILD_CONFIGURATION" == "debug" ]]; then
  plutil -insert TRIGUseDataLaunchAgent -bool YES "$APP_BUNDLE/Contents/Info.plist"
  if [[ -n "${TRIG_WIDGET_SIGN_IDENTITY:-}" ]]; then
    "$ROOT_DIR/script/sign_app.sh" "$APP_BUNDLE" "$TRIG_WIDGET_SIGN_IDENTITY" --timestamp=none
  else
    codesign --force --sign - "$WIDGET_BUNDLE"
    codesign --force --sign - "$APP_BUNDLE"
  fi
fi

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }

case "$MODE" in
  --bundle-release) echo "Built $APP_BUNDLE" ;;
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
