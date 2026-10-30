#!/bin/bash
# Build, bundle, sign, and launch UniversalVault as a menu-bar app.
#
#   ./Scripts/run.sh            # debug build
#   CONFIG=release ./Scripts/run.sh
#
# The bundle is ad-hoc signed with a stable identifier so macOS keeps the app's
# Accessibility and Keychain identity stable across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
APP="build/UniversalVault.app"
BUNDLE_ID="com.universalvault.app"
MIN_MACOS="26.0"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/UniversalVault"
if [ ! -x "$BIN" ]; then
	echo "Build product not found at $BIN" >&2
	exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UniversalVault"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>UniversalVault</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>UniversalVault</string>
  <key>CFBundleDisplayName</key><string>Universal Vault</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

# Relaunch cleanly: a running copy would otherwise stay on the old binary.
if pgrep -f "$APP/Contents/MacOS/UniversalVault" >/dev/null 2>&1; then
	echo "==> stopping the running instance"
	pkill -f "$APP/Contents/MacOS/UniversalVault" || true
	sleep 1
fi

echo "==> launching"
open "$APP"

cat <<MSG

Universal Vault is running in the menu bar.

First run:
  1. Click the menu bar icon and choose Quick Fill… (or press Control+Option+V).
  2. Create the vault when prompted.
  3. Grant Accessibility in System Settings > Privacy & Security > Accessibility.
     Re-run this script after granting it if insertion still reports permission denied.

Logs:
  log stream --predicate 'process == "UniversalVault"' --level debug
MSG
