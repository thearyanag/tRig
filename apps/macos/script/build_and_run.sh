#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
APP_EXECUTABLE="AccountWebTest"
BUNDLE="$ROOT_DIR/dist/tRig.app"
CHART_OUTPUT="$ROOT_DIR/.build/chart-host"

case "$MODE" in
  run|--verify|--build-only) ;;
  *) echo 'Usage: build_and_run.sh [run|--verify|--build-only]' >&2; exit 2 ;;
esac

for dependency in swift cargo codesign rsync npm node; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Missing required tool: $dependency. See apps/macos/README.md." >&2
    exit 1
  fi
done

# Keep the running app available if compilation fails.
npm ci --prefix "$ROOT_DIR/chart-host" --ignore-scripts --no-audit --no-fund
npm run build --prefix "$ROOT_DIR/chart-host"
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
# Mirror only generated Vela assets; this also removes stale proprietary assets.
rsync -a --delete "$CHART_OUTPUT/" "$BUNDLE/Contents/Resources/Chart/"

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
