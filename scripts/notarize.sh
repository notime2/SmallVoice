#!/bin/bash
# Builds a release DMG that opens on any Mac without Gatekeeper warnings: signs SmallVoice.app with a
# Developer ID certificate, packs it, notarizes the disk image with Apple and staples the ticket.
#
# Needs a paid Apple Developer Program membership. One-time setup:
#   xcrun notarytool store-credentials SmallVoice --apple-id you@example.com --team-id ABCDE12345
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)" scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your "Developer ID Application: …" signing identity}"
profile="${NOTARY_PROFILE:-SmallVoice}"
app="build/DerivedData/Build/Products/Release/SmallVoice.app"
dmg="build/SmallVoice.dmg"

make build CONFIG=Release

# The app has a single executable, so signing the bundle covers everything inside it.
codesign --force --timestamp --options runtime \
    --entitlements SmallVoice/Resources/SmallVoice.entitlements --sign "$DEVELOPER_ID" "$app"
codesign --verify --deep --strict "$app"

scripts/make-dmg.sh "$app" "$dmg"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$dmg"

xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Notarized $dmg"
