#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/verification
bash scripts/check-invariants.sh | tee .build/verification/invariants.log
swift test > .build/verification/tests.log 2>&1
swift build -c release > .build/verification/release.log 2>&1
python3 scripts/verify-storage-processes.py | tee .build/verification/storage-processes.log
sh -n scripts/build-app.sh
plutil -lint Packaging/Info.plist
sh scripts/build-app.sh release > .build/verification/package.log 2>&1
codesign --verify --strict .build/UniversalVault.app
if .build/UniversalVault.app/Contents/MacOS/UniversalVault --verify-native .build/verification/release-mode 2> .build/verification/release-isolation.log; then
    echo "Release unexpectedly accepted native verification mode." >&2
    exit 1
fi
grep -q 'Native verification is available only in debug builds' .build/verification/release-isolation.log
if [ "${1:-}" = "--native" ]; then
    sh scripts/build-app.sh debug --verification > .build/verification/debug-package.log 2>&1
    python3 scripts/verify-native.py --binary .build/UniversalVault-verification.app/Contents/MacOS/UniversalVault --output .build/native-verification
elif [ "$#" -gt 0 ]; then
    echo "Usage: $0 [--native]" >&2
    exit 2
fi
echo "PASS: tests, release build, cross-process storage, package signature, and release verification isolation."
