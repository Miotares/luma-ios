#!/usr/bin/env bash
#
# Packages the macOS app "Luma" into a distributable .dmg.
#
#   ./scripts/package-mac.sh            Developer ID signed (+ notarized if creds given)
#   ./scripts/package-mac.sh --local    ad-hoc signed — runs on THIS Mac only, for testing
#
# Distribution build (no --local) needs a "Developer ID Application" certificate in your
# keychain (Apple Developer Program). Create it once in Xcode ▸ Settings ▸ Accounts ▸
# Manage Certificates ▸ + ▸ "Developer ID Application", or at developer.apple.com.
#
# To also notarize automatically, set ONE of:
#   NOTARY_PROFILE=<profile>     (created via: xcrun notarytool store-credentials <profile>)
#   APPLE_ID=<id> NOTARY_PASSWORD=<app-specific-password>
# Otherwise the script prints the manual notarization commands.
set -euo pipefail

MODE="${1:-developer-id}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/Luma.xcodeproj"
SCHEME="Luma macOS"
APP_NAME="Luma"
TEAM_ID="QS5H87MR36"

BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME.dmg"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR"

echo "▸ Archive ($SCHEME, Release)…"
ARCHIVE_FLAGS=()
if [ "$MODE" = "--local" ]; then
  # Ad-hoc sign during archive so no Developer ID certificate is required.
  ARCHIVE_FLAGS=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES)
fi
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive "${ARCHIVE_FLAGS[@]}"

if [ "$MODE" = "--local" ]; then
  echo "▸ Local mode: ad-hoc signature (this Mac only)"
  cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"
  codesign --force --sign - "$APP"
else
  echo "▸ Export with Developer ID…"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$PROJECT_DIR/scripts/exportOptions.plist" \
    -exportPath "$EXPORT_DIR"
fi

echo "▸ Build DMG…"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "  → $DMG"

if [ "$MODE" != "--local" ]; then
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▸ Notarize (profile: $NOTARY_PROFILE)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  elif [ -n "${APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    echo "▸ Notarize (apple-id: $APPLE_ID)…"
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG"
  else
    cat <<NOTE

  DMG built but NOT notarized. To notarize (one-time credential setup):
    xcrun notarytool store-credentials luma-notary \\
      --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>
  then re-run:
    NOTARY_PROFILE=luma-notary ./scripts/package-mac.sh
  or notarize this DMG directly:
    xcrun notarytool submit "$DMG" --keychain-profile luma-notary --wait
    xcrun stapler staple "$DMG"
NOTE
  fi
fi

echo "✓ Done: $DMG"
