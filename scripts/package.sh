#!/bin/sh
# Build a Release Chatbridge.app and wrap it in a DMG under dist/.
#
# With a "Developer ID Application" certificate in the keychain the app is signed for
# distribution, and if a notarytool keychain profile named by NOTARY_PROFILE exists
# (create once with: xcrun notarytool store-credentials chatbridge-notary ...), the DMG is
# notarized and stapled. Without them you get a development-signed DMG that runs on this
# Mac (and other Macs registered to the team) but is blocked by Gatekeeper elsewhere.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NOTARY_PROFILE="${NOTARY_PROFILE:-chatbridge-notary}"
DIST="$ROOT/dist"
BUILD="$ROOT/app/build-release"
APP="$BUILD/Build/Products/Release/Chatbridge.app"

rm -rf "$DIST" && mkdir -p "$DIST"
xcodebuild -project "$ROOT/app/Chatbridge.xcodeproj" -scheme Chatbridge -configuration Release \
  -derivedDataPath "$BUILD" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$DIST/build.log" 2>&1 || true
grep -q "BUILD SUCCEEDED" "$DIST/build.log" || { grep -E "error:" "$DIST/build.log" | head; echo "release build failed (see dist/build.log)"; exit 1; }
touch "$BUILD/.metadata_never_index"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# Release hygiene: no development fixtures, no debugger entitlement.
if ls "$APP/Contents/Resources/profiles"/demo-* >/dev/null 2>&1; then echo "demo profiles leaked into Release"; exit 1; fi
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then echo "get-task-allow present in Release"; exit 1; fi

DEVID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [ -n "$DEVID" ]; then
  echo "signing with: $DEVID"
  codesign --force --options runtime --timestamp --entitlements "$ROOT/app/Chatbridge.entitlements.resolved" --sign "$DEVID" "$APP" 2>/dev/null \
    || codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$DEVID" "$APP"
else
  echo "no Developer ID certificate: keeping the development signature (not distributable outside your team)"
fi
codesign --verify --deep --strict "$APP"

STAGE="$DIST/stage"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Chatbridge.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Chatbridge-$VERSION.dmg"
hdiutil create -quiet -volname "Chatbridge $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ -n "$DEVID" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  codesign --force --timestamp --sign "$DEVID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "notarized and stapled"
else
  echo "not notarized (needs a Developer ID certificate and the '$NOTARY_PROFILE' notarytool profile)"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "packaged: $DMG"
