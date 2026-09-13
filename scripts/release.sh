#!/usr/bin/env bash
# Archive, sign with Developer ID, notarize, staple, and package DriveDroid as a DMG.
#
# Prereqs (one time):
#   brew install xcodegen
#   xcrun notarytool store-credentials DriveDroid --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific-password>
#
# Usage:
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/release.sh            # uses keychain profile "DriveDroid"
#   NOTARY_PROFILE=other DEVELOPMENT_TEAM=... scripts/release.sh
#   SKIP_NOTARIZE=1 DEVELOPMENT_TEAM=... scripts/release.sh   # sign only
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM="${DEVELOPMENT_TEAM:-$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig 2>/dev/null || true)}"
[[ -n "$TEAM" && "$TEAM" != XXXXXXXXXX ]] || { echo "Set DEVELOPMENT_TEAM (or Local.xcconfig)"; exit 1; }
PROFILE="${NOTARY_PROFILE:-DriveDroid}"
BUILD=build/release
ARCHIVE="$BUILD/DriveDroid.xcarchive"
EXPORT="$BUILD/export"
DMG="$BUILD/DriveDroid.dmg"

rm -rf "$BUILD"; mkdir -p "$BUILD"
xcodegen generate

xcodebuild -project DriveDroid.xcodeproj -scheme DriveDroid -configuration Release \
  -archivePath "$ARCHIVE" archive DEVELOPMENT_TEAM="$TEAM" | grep -E "error:|warning:|ARCHIVE" || true
[[ -d "$ARCHIVE" ]] || { echo "archive failed"; exit 1; }

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD/ExportOptions.plist" -exportPath "$EXPORT" | grep -E "error:|EXPORT" || true
APP="$EXPORT/DriveDroid.app"
[[ -d "$APP" ]] || { echo "export failed"; exit 1; }

# DMG with an Applications shortcut
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname DriveDroid -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "Developer ID Application" --timestamp "$DMG"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi
spctl -a -vv -t install "$APP" 2>&1 | tail -2
echo "Done: $DMG"
