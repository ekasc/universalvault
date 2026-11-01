#!/bin/sh
set -eu
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;; esac
swift build --package-path "$ROOT" -c "$CONFIG"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
APP="$ROOT/.build/UniversalVault.app"
case "${2:-}" in
    "") ;;
    --verification)
        [ "$CONFIG" = debug ] || { echo "Verification bundles require debug configuration." >&2; exit 2; }
        APP="$ROOT/.build/UniversalVault-verification.app"
        ;;
    *) echo "Usage: $0 [release|debug] [--verification]" >&2; exit 2 ;;
esac
STAGING="$(mktemp -d "$ROOT/.build/UniversalVault-stage-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
BUNDLE="$STAGING/UniversalVault.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$STAGING/AppIcon.iconset"
cp "$BIN/UniversalVault" "$BUNDLE/Contents/MacOS/UniversalVault"
cp "$ROOT/Packaging/Info.plist" "$BUNDLE/Contents/Info.plist"
swift "$ROOT/scripts/generate-icon.swift" "$STAGING/AppIcon.iconset"
iconutil -c icns "$STAGING/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
chmod +x "$BUNDLE/Contents/MacOS/UniversalVault"
plutil -lint "$BUNDLE/Contents/Info.plist"

# Keychain user-presence access control needs an embedded Mac Team profile and
# its keychain-access-groups entitlement. Without them every SecItemAdd fails
# with errSecMissingEntitlement, so the app reports a signing error instead.
PROFILE=""
PREFIX=""
if INFO="$(python3 "$ROOT/scripts/find-profile.py" 2>/dev/null)"; then
    PROFILE="$(printf '%s' "$INFO" | cut -f1)"
    PREFIX="$(printf '%s' "$INFO" | cut -f2)"
fi
if [ -n "$PROFILE" ]; then
    cp "$PROFILE" "$BUNDLE/Contents/embedded.provisionprofile"
    ENTITLEMENTS="$STAGING/UniversalVault.entitlements"
    sed "s|\$(AppIdentifierPrefix)|$PREFIX|g" \
        "$ROOT/Packaging/UniversalVault.entitlements" > "$ENTITLEMENTS"
    IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)}"
    [ -n "$IDENTITY" ] || {
        echo "A provisioning profile was found but no Apple Development identity exists." >&2
        exit 1
    }
    codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
        --timestamp=none "$BUNDLE"
else
    codesign --force --sign - "$BUNDLE"
    echo "warning: no Mac Team provisioning profile for com.universalvault.app." >&2
    echo "warning: vault creation will fail with a Keychain signing error." >&2
    echo "warning: run scripts/provision.sh, then rebuild." >&2
fi
codesign --verify --strict "$BUNDLE"
rm -rf "$APP"
mv "$BUNDLE" "$APP"
echo "$APP"
