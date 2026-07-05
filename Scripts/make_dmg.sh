#!/usr/bin/env bash
# Builds a distributable DMG (universal binary) into ./build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash Scripts/build_app.sh --universal

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)"
STAGING="$ROOT/build/dmg-staging"
DMG="$ROOT/build/Rushlight-$VERSION.dmg"

echo "▸ Packaging $DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$ROOT/build/Rushlight.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Rushlight $VERSION" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"
rm -rf "$STAGING"

echo "✓ Built $DMG"
