#!/bin/bash
# Builds an installable disk image of Coffee Can RTI DTI SAR Imaging, for Macs without Xcode:
#   Tools/make_release.sh            -> build/dist/Coffee-Can-RTI-DTI-SAR-Imaging-<version>.dmg
# The app is universal (Apple Silicon and Intel) and needs macOS 14 or later.
#
# Without an Apple Developer ID the app is ad-hoc signed, and users approve it once in
# System Settings > Privacy & Security (see "How to open.txt", included in the image).
# With a Developer ID (Apple Developer Program), sign and notarize so it opens without warnings:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> Tools/make_release.sh
# where <profile> was stored once with:  xcrun notarytool store-credentials <profile> ...
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Coffee Can RTI DTI SAR Imaging"
VERSION="${VERSION:-$(date +%Y.%m.%d)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DMG="build/dist/Coffee-Can-RTI-DTI-SAR-Imaging-$VERSION.dmg"
SIGN="${SIGN_IDENTITY:-}"

# Build outside the repo: under iCloud Drive (Documents) every file gets attributes that
# codesign rejects ("resource fork, Finder information, or similar detritus not allowed").
WORK="${TMPDIR:-/tmp}/coffee-can-release"
rm -rf "$WORK" && mkdir -p "$WORK"
echo "Building $NAME $VERSION ($BUILD_NUMBER), universal..."
EXTRA=()
if [ -n "$SIGN" ]; then
    EXTRA=(CODE_SIGN_IDENTITY="$SIGN" ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_ENTITLEMENTS="$PWD/Tools/release.entitlements" OTHER_CODE_SIGN_FLAGS=--timestamp)
fi
xcodebuild -project CoffeeCanRadar.xcodeproj -target CoffeeCanRadar -configuration Release \
    SYMROOT="$WORK/build" OBJROOT="$WORK/obj" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${EXTRA[@]+"${EXTRA[@]}"} build | grep -E "error|warning: |BUILD" || true
APP="$WORK/build/Release/$NAME.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }
xattr -cr "$APP"     # Finder/provenance attributes make strict verification fail
codesign --verify --deep --strict "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/$NAME")"

STAGE="$WORK/stage"
mkdir -p "$STAGE" && rm -rf build/dist && mkdir -p build/dist
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cat "Tools/How to open.txt" > "$STAGE/How to open.txt"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$WORK/out.dmg"
cp "$WORK/out.dmg" "$DMG"

if [ -n "$SIGN" ]; then
    codesign --sign "$SIGN" --timestamp "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi
echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
