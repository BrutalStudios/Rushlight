#!/usr/bin/env bash
# Builds Rushlight.app into ./build. Pass --universal for an arm64+x86_64 binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH_FLAGS=""
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

echo "▸ Compiling (release)…"
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN_PATH="$(swift build -c release $ARCH_FLAGS --show-bin-path)/Rushlight"

APP="$ROOT/build/Rushlight.app"
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/Rushlight"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -f "$ROOT/Support/Rushlight.icns" ]]; then
    cp "$ROOT/Support/Rushlight.icns" "$APP/Contents/Resources/Rushlight.icns"
fi

echo "▸ Code signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "✓ Built $APP"
echo "  Run it with: open \"$APP\""
