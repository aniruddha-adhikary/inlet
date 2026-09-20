#!/bin/sh
# Build a Release Inlet.app and wrap it in a DMG under dist/.
#
# With a paid Apple Developer Program team the app is exported with a Developer ID signature,
# and if a notarytool keychain profile named by NOTARY_PROFILE exists (create once with:
# xcrun notarytool store-credentials inlet-notary ...), the app and the DMG are notarized and
# stapled. Without them you get a DMG that Gatekeeper blocks on other people's Macs.
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

# Inlet uses the keychain and an application identifier. Outside the App Store those need a
# Developer ID provisioning profile inside the app, so re-signing the built app by hand is not
# enough: archive, then let Xcode export it for Developer ID. With automatic signing Xcode uses a
# cloud-managed Developer ID certificate, so none has to be in the local keychain. This needs a
# paid Apple Developer Program team; without one the export fails and the development build is kept.
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$ROOT/app/Config/Local.xcconfig" 2>/dev/null | head -1)
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
DEVID=""
if [ -n "$TEAM" ] \
  && xcodebuild -project "$ROOT/app/Inlet.xcodeproj" -scheme Inlet -configuration Release -derivedDataPath "$BUILD" \
       -archivePath "$ARCHIVE" -allowProvisioningUpdates archive >> "$DIST/build.log" 2>&1 \
  && xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$DIST/export" \
       -exportOptionsPlist "$DIST/ExportOptions.plist" -allowProvisioningUpdates >> "$DIST/build.log" 2>&1 \
  && codesign -dvv "$DIST/export/Inlet.app" 2>&1 | grep -q "Authority=Developer ID Application"; then
  APP="$DIST/export/Inlet.app"
  DEVID=yes
  echo "signed with Developer ID"
  if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then echo "get-task-allow present in export"; exit 1; fi
else
  echo "no Developer ID export (needs a paid developer team): keeping the development signature, not distributable"
fi
codesign --verify --deep --strict "$APP"

CAN_NOTARIZE=""
if [ -n "$DEVID" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then CAN_NOTARIZE=yes; fi

# Notarize and staple the app itself first, so it passes Gatekeeper even once copied out of the DMG offline.
if [ -n "$CAN_NOTARIZE" ]; then
  ditto -c -k --keepParent "$APP" "$DIST/Inlet.zip"
  xcrun notarytool submit "$DIST/Inlet.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$DIST/Inlet.zip"
fi

STAGE="$DIST/stage"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Inlet.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Inlet-$VERSION.dmg"
hdiutil create -quiet -volname "Inlet $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ -n "$CAN_NOTARIZE" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type execute -v "$APP"
  echo "notarized and stapled: ready to publish"
elif [ -n "$DEVID" ]; then
  echo "NOT notarized: Gatekeeper will block this on other Macs. Store credentials once with:"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id <your team id>"
fi
rm -rf "$DIST/export" "$ARCHIVE" "$DIST/ExportOptions.plist"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "packaged: $DMG"
