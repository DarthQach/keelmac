#!/usr/bin/env bash
# Builds a signed, notarized release: archive → Developer ID export → notarize + staple → DMG → notarize + staple
# → Sparkle signature → appcast/releases.json → cask sha256.
#
# Needs (environment): NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD (app-specific password),
# a "Developer ID Application" certificate in the keychain, and the Sparkle EdDSA private key
# (login keychain account "keelmac", or SPARKLE_PRIVATE_KEY in CI).
#   bash scripts/release.sh 1.0.0 1 "Release note line" "Another line"
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$1"; BUILD="$2"; shift 2
DD=build/DerivedData
ARCHIVE=build/KeelMac.xcarchive
EXPORT=build/export
SPARKLE_BIN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"

xcodegen generate --quiet
xcodebuild -project KeelMac.xcodeproj -scheme KeelMac -configuration Release -derivedDataPath "$DD" \
  -archivePath "$ARCHIVE" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" archive | tail -3

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${NOTARY_TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist build/ExportOptions.plist | tail -2

notarize() {
  xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
}

(cd "$EXPORT" && ditto -c -k --keepParent KeelMac.app KeelMac.zip)
notarize "$EXPORT/KeelMac.zip"
xcrun stapler staple "$EXPORT/KeelMac.app"
mkdir -p dist && rm -rf dist/KeelMac.app && cp -R "$EXPORT/KeelMac.app" dist/
DMG=$(bash scripts/make_dmg.sh dist/KeelMac.app "$VERSION")
notarize "$DMG"
xcrun stapler staple "$DMG"

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  SIG=$(echo "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$DMG")
else
  SIG=$("$SPARKLE_BIN/sign_update" --account keelmac -p "$DMG")
fi
URL="https://github.com/DarthQach/keelmac/releases/download/v$VERSION/KeelMac-$VERSION.dmg"
node scripts/appcast.mjs --add "$VERSION" "$BUILD" "$DMG" "$URL" "$SIG" "$@"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/keelmac.rb
(cd site && node build.mjs && node check.mjs)
echo "release $VERSION ready: $DMG (sha256 $SHA)"
