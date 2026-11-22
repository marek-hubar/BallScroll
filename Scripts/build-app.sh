#!/bin/bash
# Build BallScroll.app into ./build. Needs only the Xcode Command Line Tools.
#
#   Scripts/build-app.sh              universal (Apple silicon + Intel) release build
#   ARCHS=arm64 Scripts/build-app.sh  one architecture only
#
# Signing: by default the app is ad-hoc signed, which is enough to run it.
# macOS ties the Accessibility grant to the exact build of an ad-hoc signed
# app, so after every rebuild you have to grant access again. To keep the
# grant across rebuilds, sign with a stable identity:
#
#   SIGN_IDENTITY="Your Signing Identity" Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="BallScroll"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/$APP_NAME.app"

binaries=()
for arch in $ARCHS; do
    echo "==> Building $arch"
    swift build -c release --triple "$arch-apple-macosx14.0"
    binaries+=("$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/$APP_NAME")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ${#binaries[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
    cp "${binaries[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi

echo "==> Signing (${SIGN_IDENTITY/#-/ad-hoc})"
codesign --force --sign "$SIGN_IDENTITY" \
    --identifier "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)" \
    "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
