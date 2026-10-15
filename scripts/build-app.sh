#!/bin/sh
set -eu
CONFIG="${1:-release}"
swift build -c "$CONFIG"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/UniversalVault.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIG/UniversalVault" "$APP/Contents/MacOS/UniversalVault"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/UniversalVault"
codesign --force --deep --sign - "$APP"
echo "$APP"
