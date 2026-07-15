#!/usr/bin/env bash
#
#  File:      package.sh
#  Created:   2026-06-09
#  Updated:   2026-06-14
#  Developer: Kennt Kim / Calida Lab
#  Overview:  Builds release SiliconScope.app, Developer ID–signs it (hardened runtime),
#             notarizes + staples it, then ships a notarized DMG with an /Applications
#             drop link.
#  Notes:     SPM emits no .app, so Contents/{MacOS,Resources} + Info.plist are assembled
#             by hand; the SPM resource bundle is copied alongside a top-level
#             AppIcon.icns. Requires a stored notarytool keychain profile. The profile
#             name (NOTARY_PROFILE) is a pre-existing local keychain credential kept
#             as "WhisPlayInfo-notary" so notarization works without re-auth.
#             Usage: scripts/package.sh [version] [--critical] [--notes FILE]
#               --critical    mark this release as a Sparkle critical update (NOT the
#                             default — most releases are ordinary updates). Users below
#                             this version then cannot skip it and are prompted promptly.
#               --notes FILE  Markdown/HTML release notes injected as the appcast
#                             <description> shown in Sparkle's update dialog. Defaults to
#                             docs/release-notes/v<version>.md if that file exists.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# --- Argument parsing: positional [version] plus optional flags (order-independent) ---
VERSION=""
CRITICAL=0
NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --critical)      CRITICAL=1; shift ;;
    --notes)         NOTES_FILE="${2:-}"; shift 2 ;;
    --notes=*)       NOTES_FILE="${1#*=}"; shift ;;
    -*)              echo "Unknown flag: $1" >&2; exit 2 ;;
    *)               [ -z "$VERSION" ] && VERSION="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift ;;
  esac
done
VERSION="${VERSION:-1.0.0}"
APP="SiliconScope"
BUNDLE_ID="ai.calidalab.SiliconScope"
IDENTITY="Developer ID Application: YONG SOO KIM (8677QL77VJ)"
NOTARY_PROFILE="WhisPlayInfo-notary"   # pre-existing local keychain profile (kept to avoid re-auth)
DIST="dist"
APPDIR="$DIST/$APP.app"

# --- Sparkle auto-update ---
# EdDSA public key (private half lives in the login keychain; created via generate_keys).
SU_PUBLIC_KEY="mhjyc+aHQkMYFZInv/15en9GVk/9eBEQN10QLOFwWJU="
REPO="kennss/SiliconScope"
# Appcast is served from the LATEST GitHub release as a stable URL that redirects per release.
SU_FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
SPARKLE_FW_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"

echo "▸ Building release binary…"
xcrun swift build -c release --product "$APP"
BIN=".build/release/$APP"
RES_BUNDLE=".build/release/SiliconScope_${APP}.bundle"
ICON="Sources/$APP/Resources/AppIcon.icns"

echo "▸ Assembling $APP.app…"
rm -rf "$DIST"; mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"
cp "$ICON" "$APPDIR/Contents/Resources/AppIcon.icns"
[ -d "$RES_BUNDLE" ] && cp -R "$RES_BUNDLE" "$APPDIR/Contents/Resources/"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>SUFeedURL</key><string>$SU_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SU_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

echo "▸ Embedding Sparkle.framework…"
mkdir -p "$APPDIR/Contents/Frameworks"
cp -R "$SPARKLE_FW_SRC" "$APPDIR/Contents/Frameworks/"
# The SPM binary links @rpath/Sparkle.framework; point rpath at the bundle's Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APPDIR/Contents/MacOS/$APP" 2>/dev/null || true

echo "▸ Signing (Developer ID, hardened runtime)…"
# Sparkle: sign nested helpers (deep -> shallow), then the framework, then the app last.
SPARKLE_FW="$APPDIR/Contents/Frameworks/Sparkle.framework"
SPV="$SPARKLE_FW/Versions/$(ls "$SPARKLE_FW/Versions" | grep -v Current | head -1)"
for nested in \
  "$SPV/XPCServices/Installer.xpc" \
  "$SPV/XPCServices/Downloader.xpc" \
  "$SPV/Autoupdate" \
  "$SPV/Updater.app"; do
  [ -e "$nested" ] && codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW"
# The SPM resource bundle is a flat resource folder (no Info.plist / no code), so it is
# sealed by the app signature — do NOT sign it separately. Sign the app last to seal all.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APPDIR"
codesign --verify --strict --verbose=2 "$APPDIR"

echo "▸ Notarizing app…"
ZIP="$DIST/$APP-notarize.zip"
ditto -c -k --keepParent "$APPDIR" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APPDIR"
rm -f "$ZIP"

echo "▸ Building DMG…"
STAGE="$DIST/.stage"; mkdir -p "$STAGE"
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP-$VERSION.dmg"
hdiutil create -volname "$APP $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "▸ Notarizing DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "▸ Generating Sparkle appcast…"
# generate_appcast signs the DMG with the keychain EdDSA key and writes appcast.xml whose
# enclosure URL points at this release's GitHub asset. Upload BOTH the DMG and appcast.xml
# to the v$VERSION GitHub release; SUFeedURL resolves to the latest release's appcast.xml.
APPCAST_DIR="$DIST/appcast"; mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
if [ -x "$GENERATE_APPCAST" ]; then
  "$GENERATE_APPCAST" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$APPCAST_DIR"

  # Default release-notes file if none passed and the conventional one exists.
  if [ -z "$NOTES_FILE" ] && [ -f "docs/release-notes/v$VERSION.md" ]; then
    NOTES_FILE="docs/release-notes/v$VERSION.md"
  fi

  # Post-process: generate_appcast never emits <sparkle:criticalUpdate> or a <description>,
  # so inject them here — critical ONLY when --critical was passed (most releases are not).
  VERSION="$VERSION" CRITICAL="$CRITICAL" NOTES_FILE="$NOTES_FILE" \
    python3 scripts/appcast_annotate.py "$APPCAST_DIR/appcast.xml"

  cp "$APPCAST_DIR/appcast.xml" "$DIST/appcast.xml"
  echo "✓ $DIST/appcast.xml  (critical=$CRITICAL${NOTES_FILE:+, notes=$NOTES_FILE})"
else
  echo "⚠︎ generate_appcast not found ($GENERATE_APPCAST) — run 'xcrun swift build' first."
fi

echo ""
echo "▸ Gatekeeper check:"
spctl -a -vvv "$APPDIR" 2>&1 || true
echo ""
echo "✓ $APPDIR  (signed, notarized, stapled)"
echo "✓ $DMG"
ls -lh "$DMG"
echo ""
echo "Next: upload BOTH to the v$VERSION GitHub release:"
echo "  gh release create v$VERSION \"$DMG\" \"$DIST/appcast.xml\" --title \"v$VERSION\" --notes-file ..."
if [ "$CRITICAL" = "1" ]; then
  echo ""
  echo "⚠︎ This appcast is marked CRITICAL — users below $VERSION will be prompted promptly"
  echo "  and cannot skip it. (Ordinary releases: omit --critical.)"
fi
