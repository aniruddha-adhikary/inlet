#!/bin/sh
# Build a Release Inlet.app and wrap it in a DMG under dist/.
#
# With a "Developer ID Application" certificate in the keychain the app is signed for
# distribution, and if a notarytool keychain profile named by NOTARY_PROFILE exists
# (create once with: xcrun notarytool store-credentials inlet-notary ...), the DMG is
# notarized and stapled. Without them you get a development-signed DMG that runs on this
# Mac (and other Macs registered to the team) but is blocked by Gatekeeper elsewhere.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NOTARY_PROFILE="${NOTARY_PROFILE:-inlet-notary}"
DIST="$ROOT/dist"
BUILD="$ROOT/app/build-release"
APP="$BUILD/Build/Products/Release/Inlet.app"

rm -rf "$DIST" && mkdir -p "$DIST"
xcodebuild -project "$ROOT/app/Inlet.xcodeproj" -scheme Inlet -configuration Release \
  -derivedDataPath "$BUILD" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$DIST/build.log" 2>&1 || true
grep -q "BUILD SUCCEEDED" "$DIST/build.log" || { grep -E "error:" "$DIST/build.log" | head; echo "release build failed (see dist/build.log)"; exit 1; }
touch "$BUILD/.metadata_never_index"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# Release hygiene: no development fixtures, no debugger entitlement.
if ls "$APP/Contents/Resources/profiles"/demo-* >/dev/null 2>&1; then echo "demo profiles leaked into Release"; exit 1; fi
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then echo "get-task-allow present in Release"; exit 1; fi

DEVID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [ -n "$DEVID" ]; then
  # Inlet uses the keychain and an application identifier. Outside the App Store those need a
  # Developer ID provisioning profile inside the app, so re-signing the built app by hand is not
  # enough: archive, then let Xcode export it for Developer ID (it fetches the profile).
  echo "signing with: $DEVID"
  TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$ROOT/app/Config/Local.xcconfig" | head -1)
  [ -n "$TEAM" ] || { echo "DEVELOPMENT_TEAM missing from app/Config/Local.xcconfig"; exit 1; }
  ARCHIVE="$DIST/Inlet.xcarchive"
  cat > "$DIST/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
PLIST
  xcodebuild -project "$ROOT/app/Inlet.xcodeproj" -scheme Inlet -configuration Release -derivedDataPath "$BUILD" \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates archive >> "$DIST/build.log" 2>&1 \
    || { grep -E "error:" "$DIST/build.log" | tail -5; echo "archive failed (see dist/build.log)"; exit 1; }
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$DIST/export" \
    -exportOptionsPlist "$DIST/ExportOptions.plist" -allowProvisioningUpdates >> "$DIST/build.log" 2>&1 \
    || { grep -E "error:" "$DIST/build.log" | tail -5; echo "Developer ID export failed (see dist/build.log)"; exit 1; }
  APP="$DIST/export/Inlet.app"
  codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "export is not Developer ID signed"; exit 1; }
  if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then echo "get-task-allow present in export"; exit 1; fi
else
  echo "no Developer ID certificate: keeping the development signature (not distributable outside your team)"
fi
codesign --verify --deep --strict "$APP"

STAGE="$DIST/stage"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Inlet.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Inlet-$VERSION.dmg"
hdiutil create -quiet -volname "Inlet $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE" "$DIST/export" "$DIST/Inlet.xcarchive" "$DIST/ExportOptions.plist"

if [ -n "$DEVID" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  codesign --force --timestamp --sign "$DEVID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "notarized and stapled"
else
  echo "not notarized (needs a Developer ID certificate and the '$NOTARY_PROFILE' notarytool profile)"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "packaged: $DMG"
