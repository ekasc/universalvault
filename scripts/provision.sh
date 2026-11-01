#!/bin/sh
# Create or renew the Mac Team provisioning profile that lets UniversalVault
# use Keychain user-presence access control. Profiles from a Personal Team
# expire after seven days, so this has to be re-run after that.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="${DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ]; then
    TEAM="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p' | head -1)"
fi
[ -n "$TEAM" ] || { echo "No development team found. Pass DEVELOPMENT_TEAM=<team id>." >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild is required." >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/universalvault-provision-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
cp -R "$ROOT/Packaging/Provisioning/Provisioning.xcodeproj" "$STAGE/"
cp -R "$ROOT/Packaging/Provisioning/Provisioning" "$STAGE/"
if ! xcodebuild -project "$STAGE/Provisioning.xcodeproj" -scheme Provisioning \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$STAGE/dd" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" build >"$STAGE/build.log" 2>&1
then
    grep -E "error:" "$STAGE/build.log" | head -5 >&2
    echo "Provisioning failed. Sign in to Xcode with an Apple ID that has a team." >&2
    exit 1
fi
python3 "$ROOT/scripts/find-profile.py"
