#!/bin/bash
# Structural guards for invariants that reviews keep re-checking by eye.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

if grep -RInE --include='*.swift' 'NSPasteboard|generalPasteboard|NSPasteboardItem' "$ROOT/Sources"; then
  echo "FAIL: clipboard APIs are not allowed in Sources." >&2
  fail=1
fi

if grep -RInE --include='*.swift' '\b(print|debugPrint|NSLog)[[:space:]]*\(' "$ROOT/Sources"; then
  echo "FAIL: print and NSLog are not allowed in Sources; use the debug verifier's evidence files." >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: no clipboard APIs and no print or NSLog calls in Sources."
fi
exit "$fail"
