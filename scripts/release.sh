#!/bin/sh
# Builds a release of Ommateum. With Developer ID settings it also signs, notarizes and staples.
#
#   OMMATEUM_BUNDLE_ID   final bundle identifier (default: the one in the project)
#   DEVELOPER_ID         e.g. "Developer ID Application: Name (TEAMID)"; omit for an ad-hoc signed local build
#   NOTARY_PROFILE       keychain profile created with `xcrun notarytool store-credentials`
set -eu

cd "$(dirname "$0")/.."
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

set -- -project Ommateum.xcodeproj -scheme Ommateum -configuration Release -derivedDataPath "$OUT/derived"
if [ -n "${OMMATEUM_BUNDLE_ID:-}" ]; then
    set -- "$@" "PRODUCT_BUNDLE_IDENTIFIER=$OMMATEUM_BUNDLE_ID"
fi
if [ -n "${DEVELOPER_ID:-}" ]; then
    set -- "$@" "CODE_SIGN_IDENTITY=$DEVELOPER_ID" OTHER_CODE_SIGN_FLAGS=--timestamp
fi
xcodebuild "$@" build

APP="$OUT/Ommateum.app"
cp -R "$OUT/derived/Build/Products/Release/Ommateum.app" "$APP"
codesign --verify --strict --verbose=1 "$APP"
ZIP="$OUT/Ommateum.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -z "${DEVELOPER_ID:-}" ]; then
    echo "Ad-hoc signed build: $APP (runs on this Mac only; set DEVELOPER_ID to distribute)"
    exit 0
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "Signed but not notarized: $APP (set NOTARY_PROFILE to notarize)"
    exit 0
fi
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "Notarized: $ZIP"
