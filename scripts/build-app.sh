#!/usr/bin/env bash
#
#  File:      build-app.sh
#  Created:   2026-06-12
#  Updated:   2026-07-21
#  Overview:  Builds a local SiliconScope.app bundle from the SwiftPM executable.
#  Notes:     This is for development/local install. It does not notarize or create
#             a DMG; use scripts/package.sh for Developer ID distribution.
#             Embeds Sparkle.framework (ad-hoc signed) so the bundle actually launches —
#             the SPM binary links @rpath/Sparkle.framework.
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP="SiliconScope"
BUNDLE_ID="${BUNDLE_ID:-ai.calidalab.SiliconScope}"
CONFIG="${CONFIG:-release}"
# Signing identity. Default is ad-hoc ("-") for a throwaway local install. For features gated by
# macOS Local Network / TCC privacy (the Fleet view's mDNS + HTTP), ad-hoc signatures have an
# unstable designated requirement that TCC won't track — set SIGN_ID to a Developer ID Application
# identity so the app gets a stable identity and the Local Network prompt actually appears:
#   SIGN_ID="Developer ID Application: YONG SOO KIM (8677QL77VJ)" scripts/build-app.sh
SIGN_ID="${SIGN_ID:--}"
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
  <key>NSLocalNetworkUsageDescription</key><string>SiliconScope discovers monitoring agents on your local network to show remote machines (e.g. a Linux GPU box) in the Fleet view.</string>
  <key>NSBonjourServices</key>
  <array><string>_sscope-agent._tcp</string></array>
</dict>
</plist>
PLIST

echo "Embedding Sparkle.framework..."
mkdir -p "$APPDIR/Contents/Frameworks"
cp -R "$BIN_DIR/Sparkle.framework" "$APPDIR/Contents/Frameworks/"
# The SPM binary links @rpath/Sparkle.framework; point rpath at the bundle's Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APPDIR/Contents/MacOS/$APP" 2>/dev/null || true

echo "Signing (identity: $SIGN_ID)..."
# Sparkle: sign nested helpers (deep -> shallow), then the framework, then the app last.
SPARKLE_FW="$APPDIR/Contents/Frameworks/Sparkle.framework"
SPV="$SPARKLE_FW/Versions/$(ls "$SPARKLE_FW/Versions" | grep -v Current | head -1)"
for nested in \
  "$SPV/XPCServices/Installer.xpc" \
  "$SPV/XPCServices/Downloader.xpc" \
  "$SPV/Autoupdate" \
  "$SPV/Updater.app"; do
  [ -e "$nested" ] && codesign --force --sign "$SIGN_ID" --timestamp=none "$nested"
done
codesign --force --sign "$SIGN_ID" --timestamp=none "$SPARKLE_FW"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APPDIR"
codesign --verify --strict --verbose=2 "$APPDIR"

echo "Built $APPDIR"
echo "  Open with: open \"$APPDIR\""
