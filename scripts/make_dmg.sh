#!/usr/bin/env bash
# Packs an app into a compressed DMG with an Applications shortcut.
#   bash scripts/make_dmg.sh dist/KeelMac.app 1.0.0   →   dist/KeelMac-1.0.0.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/KeelMac.app}"
VERSION="${2:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
OUT="dist/KeelMac-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/KeelMac.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist && rm -f "$OUT"
hdiutil create -quiet -volname "KeelMac $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT"
echo "$OUT"
