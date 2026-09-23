#!/bin/bash
# Packs an app bundle into a compressed disk image with an Applications shortcut.
# Usage: scripts/make-dmg.sh path/to/SmallVoice.app path/to/SmallVoice.dmg
set -euo pipefail

app="$1"
dmg="$2"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

ditto "$app" "$staging/SmallVoice.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname SmallVoice -srcfolder "$staging" -format UDZO "$dmg"
echo "Created $dmg"
