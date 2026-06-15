#!/usr/bin/env bash
#
#  File:      build-app.sh
#  Created:   2026-06-12
#  Updated:   2026-06-14
#  Overview:  Builds a local SiliconScope.app bundle from the SwiftPM executable.
#  Notes:     This is for development/local install. It does not notarize or create
#             a DMG; use scripts/package.sh for Developer ID distribution.
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP="SiliconScope"
BUNDLE_ID="${BUNDLE_ID:-ai.calidalab.SiliconScope}"
CONFIG="${CONFIG:-release}"
DIST="${DIST:-dist}"
APPDIR="$DIST/$APP.app"
ICON="Sources/$APP/Resources/AppIcon.icns"

echo "Building $APP ($CONFIG)..."
xcrun swift build -c "$CONFIG" --product "$APP"

BIN_DIR="$(xcrun swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP"
RES_BUNDLE="$BIN_DIR/SiliconScope_${APP}.bundle"

echo "Assembling $APPDIR..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

cp "$BIN" "$APPDIR/Contents/MacOS/$APP"
cp "$ICON" "$APPDIR/Contents/Resources/AppIcon.icns"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APPDIR/Contents/Resources/"
fi

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Ad-hoc signing..."
codesign --force --sign - --timestamp=none "$APPDIR"
codesign --verify --strict --verbose=2 "$APPDIR"

echo "Built $APPDIR"
echo "  Open with: open \"$APPDIR\""
