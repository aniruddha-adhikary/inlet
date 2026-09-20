#!/bin/sh
# Build the Mac app and install it to /Applications, where Siri and Spotlight
# look for installed apps (they ignore a bundle running from a build folder).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CONFIG="${CONFIG:-Debug}"
BUILT="$ROOT/app/build/Build/Products/$CONFIG/Chatbridge.app"
DEST="/Applications/Chatbridge.app"

xcodebuild -project "$ROOT/app/Chatbridge.xcodeproj" -scheme Chatbridge -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/app/build" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$ROOT/app/build/last-build.log" 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$ROOT/app/build/last-build.log" || true
grep -q "BUILD SUCCEEDED" "$ROOT/app/build/last-build.log" || { echo "build failed; not installing"; exit 1; }

pkill -x Chatbridge 2>/dev/null || true
while pgrep -x Chatbridge >/dev/null; do sleep 1; done

touch "$ROOT/app/build/.metadata_never_index" # keep the duplicate bundle out of Spotlight
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
# Two bundles with one bundle id confuse LaunchServices: keep only the installed one registered.
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true
"$LSREGISTER" -f "$DEST"
codesign --verify --deep "$DEST" && echo "installed and signature valid: $DEST"
open "$DEST"
