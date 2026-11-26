#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${TRIG_DEVELOPER_ID:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/{print $2}')"
  if [[ -z "$IDENTITIES" || "$IDENTITIES" == *$'\n'* ]]; then
    echo 'Set TRIG_DEVELOPER_ID to the name or SHA-1 of a valid Developer ID Application identity.' >&2
    exit 1
  fi
  IDENTITY="$IDENTITIES"
fi

ARCH="$(uname -m)"
mkdir -p "$ROOT/dist"
WORK="$(mktemp -d "$ROOT/dist/.dmg-work.XXXXXX")"
MOUNT="$WORK/mounted"
cleanup() {
  if [[ "${MOUNTED:-0}" == 1 ]]; then
    hdiutil detach "$MOUNT" -quiet || return
  fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/staging" "$MOUNT"
APP="$WORK/staging/tRig.app"
"$ROOT/script/build_and_run.sh" --bundle-release "$APP"
PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"

"$ROOT/script/sign_app.sh" "$APP" "$IDENTITY" --timestamp
codesign --verify --deep --strict "$APP"

ln -s /Applications "$WORK/staging/Applications"
DMG="$WORK/tRig-$VERSION-mac-$ARCH-review.dmg"
hdiutil create -quiet -volname 'tRig' -srcfolder "$WORK/staging" -fs HFS+ -format UDZO "$DMG"
codesign --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify "$DMG"
hdiutil verify -quiet "$DMG"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
MOUNTED=1
codesign --verify --deep --strict "$MOUNT/tRig.app"
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]]
hdiutil detach "$MOUNT" -quiet
MOUNTED=0

OUTPUT="$ROOT/dist/${DMG##*/}"
mv -f "$DMG" "$OUTPUT"
echo "Signed local review image: $OUTPUT"
echo 'Apple notarization is a separate step for distribution.'
