#!/bin/bash
# Build a distributable Irekobox: archive, sign every executable with
# the team's Developer ID (hardened runtime, timestamp), notarize and staple
# when a notarytool profile exists, then zip, DMG and appcast.json.
#
#   scripts/release.sh                     # everything
#   scripts/release.sh --skip-notarize     # signed but not notarized (local testing)
#
# Environment:
#   APPCAST_URL        baked into Info.plist (IrekoboxAppcastURL): where the app looks for updates;
#                      default: https://irekobox.com/appcast.json
#   DOWNLOAD_BASE_URL  where the zip will be published (for appcast.json); default: next to APPCAST_URL
#   NOTARY_PROFILE     notarytool keychain profile (default: irekobox-notary); create it once with
#                      xcrun notarytool store-credentials irekobox-notary --apple-id … --team-id YBKR9G3374
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                      an App Store Connect API key used directly instead of the profile
#                      (no keychain needed, e.g. when it is locked)
#
# Output in build/release/: Irekobox.app, Irekobox-<version>.zip, .dmg, appcast.json.
set -euo pipefail
APPCAST_URL="${APPCAST_URL-https://irekobox.com/appcast.json}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
TEAM="YBKR9G3374"
PROFILE="${NOTARY_PROFILE:-irekobox-notary}"
if [ -n "${NOTARY_KEY:-}" ]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    NOTARY_AUTH=(--keychain-profile "$PROFILE")
fi
NOTARIZE=1
[ "${1:-}" = "--skip-notarize" ] && NOTARIZE=0

# The archive is built from the working tree: a release must be exactly a
# commit, not whatever else is lying around in it (ALLOW_DIRTY=1 overrides).
if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    echo "Uncommitted changes in $ROOT; commit or set them aside first:" >&2
    git -C "$ROOT" status --short --untracked-files=no >&2
    exit 1
fi

VERSION=$(grep -m1 'MARKETING_VERSION' "$ROOT/project.yml" | sed -E 's/.*"(.*)".*/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$ROOT/project.yml" | sed -E 's/.*"(.*)".*/\1/')
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "$TEAM" | head -1 | sed -E 's/.*"(.*)"/\1/')
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity for team $TEAM" >&2; exit 1; }
echo "==> Irekobox $VERSION ($BUILD), signing as: $IDENTITY"

mkdir -p "$OUT"
ARCHIVE="$OUT/Irekobox.xcarchive"
APP="$OUT/Irekobox.app"
# Fresh output folders, renamed aside rather than deleted recursively.
for old in "$ARCHIVE" "$APP"; do [ -e "$old" ] && mv "$old" "$OUT/.old-$(date +%s)-$(basename "$old")"; done

echo "==> Archiving"
(cd "$ROOT" && xcodegen >/dev/null)
xcodebuild archive -project "$ROOT/Irekobox.xcodeproj" -scheme IrekoboxApp -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -quiet
cp -R "$ARCHIVE/Products/Applications/Irekobox.app" "$APP"

if [ -n "${APPCAST_URL:-}" ]; then
    /usr/libexec/PlistBuddy -c "Delete :IrekoboxAppcastURL" "$APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :IrekoboxAppcastURL string $APPCAST_URL" "$APP/Contents/Info.plist"
fi

echo "==> Signing (inside out)"
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
# Same identifiers as their bundle IDs in project.yml. Entitlements are
# given explicitly: re-signing drops the ones the archive was built with.
sign --identifier com.irekobox.agent "$APP/Contents/MacOS/IrekoboxAgent"
sign --identifier com.irekobox.mcp "$APP/Contents/MacOS/IrekoboxMCP"
sign --identifier com.irekobox.socketlink "$APP/Contents/MacOS/IrekoboxSocketLink"
if [ -d "$APP/Contents/Frameworks" ]; then
    find "$APP/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0 \
        | while IFS= read -r -d '' item; do sign "$item"; done
fi
for appex in "$APP"/Contents/PlugIns/*.appex; do
    [ -e "$appex" ] && sign --entitlements "$ROOT/Resources/Widgets.entitlements" "$appex"
done
sign --entitlements "$ROOT/Resources/Irekobox.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "    signature ok"

ZIP="$OUT/Irekobox-$VERSION.zip"
if [ "$NOTARIZE" = 1 ]; then
    if xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
        echo "==> Notarizing (profile $PROFILE)"
        ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
        xcrun notarytool submit "$OUT/notarize.zip" "${NOTARY_AUTH[@]}" --wait
        xcrun stapler staple "$APP"
        spctl --assess --type execute --verbose "$APP"
    else
        echo "!! No notarytool profile '$PROFILE': not notarized (updates refuse un-notarized builds)." >&2
    fi
fi

echo "==> Packaging"
[ -e "$ZIP" ] && mv "$ZIP" "$OUT/.old-$(date +%s)-$(basename "$ZIP")"
ditto -c -k --keepParent "$APP" "$ZIP"
DMG="$OUT/Irekobox-$VERSION.dmg"
[ -e "$DMG" ] && mv "$DMG" "$OUT/.old-$(date +%s)-$(basename "$DMG")"
hdiutil create -quiet -volname "Irekobox" -srcfolder "$APP" -ov -format UDZO "$DMG"
sign "$DMG"
if [ "$NOTARIZE" = 1 ] && xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
    echo "==> Notarizing the disk image"
    xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
    xcrun stapler staple "$DMG"
fi

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
BASE="${DOWNLOAD_BASE_URL:-${APPCAST_URL%/*}}"
cat > "$OUT/appcast.json" <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$BASE/$(basename "$ZIP")",
  "sha256": "$SHA",
  "minimumSystemVersion": "26.0",
  "notes": ""
}
JSON
echo "==> Done: $OUT"
ls -la "$OUT" | grep -vE " \.old-"
