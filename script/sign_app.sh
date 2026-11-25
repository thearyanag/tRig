#!/usr/bin/env bash
set -euo pipefail

APP="$1"
IDENTITY="$2"
TIMESTAMP="$3"
FLAGS=(--force --options runtime "$TIMESTAMP" --sign "$IDENTITY")
WIDGET="$APP/Contents/PlugIns/PortfolioPulseWidget.appex"
HELPER="$APP/Contents/Helpers/trading-data-service"
TDLIB="$APP/Contents/Frameworks/libtdjson.dylib"

# Derive the App Group prefix from the certificate actually used for signing.
SIGNING_SAMPLE="$HELPER"
if [[ ! -f "$HELPER" ]]; then
  EXECUTABLE="$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
  SIGNING_SAMPLE="$APP/Contents/MacOS/$EXECUTABLE"
fi
codesign "${FLAGS[@]}" "$SIGNING_SAMPLE"
TEAM="$(codesign -dv --verbose=4 "$SIGNING_SAMPLE" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo 'Portfolio Pulse needs an Apple signing identity with a developer team.' >&2
  exit 1
fi
GROUP="$TEAM.com.aryan.TradingWorkspace.portfolio"
for BUNDLE in "$APP" "$WIDGET"; do
  plutil -remove TRIGPortfolioAppGroup "$BUNDLE/Contents/Info.plist" 2>/dev/null || true
  plutil -insert TRIGPortfolioAppGroup -string "$GROUP" "$BUNDLE/Contents/Info.plist"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/trig-sign.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
for KIND in host widget; do
  cat > "$WORK/$KIND.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.application-groups</key><array><string>$GROUP</string></array>
PLIST
  if [[ "$KIND" == "widget" ]]; then
    printf '%s\n' '  <key>com.apple.security.app-sandbox</key><true/>' >> "$WORK/$KIND.plist"
  fi
  printf '%s\n' '</dict></plist>' >> "$WORK/$KIND.plist"
done

if [[ -f "$TDLIB" ]]; then codesign "${FLAGS[@]}" "$TDLIB"; fi
codesign "${FLAGS[@]}" --entitlements "$WORK/widget.plist" "$WIDGET"
codesign "${FLAGS[@]}" --entitlements "$WORK/host.plist" "$APP"
codesign --verify --deep --strict "$APP"
