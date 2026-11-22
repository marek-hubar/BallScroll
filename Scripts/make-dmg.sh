#!/bin/bash
# Package build/BallScroll.app into a drag-to-install disk image.
# Run Scripts/build-app.sh first.
#
#   Scripts/make-dmg.sh           build/BallScroll-<version>.dmg (version from Info.plist)
#   VERSION=1.2.0 Scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="BallScroll"
APP="build/$APP_NAME.app"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="build/$APP_NAME-$VERSION.dmg"

[[ -d "$APP" ]] || { echo "error: $APP not found, run Scripts/build-app.sh first" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$DMG"

echo "==> Done: $DMG"
