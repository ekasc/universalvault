#!/usr/bin/env python3
"""Print the newest valid macOS provisioning profile for UniversalVault.

Output: one line, "<profile path>\t<app identifier prefix>", where the prefix
includes the trailing dot (for example "3D973X589K."). Exit status 1 when no
usable profile is installed.
"""

import glob
import os
import plistlib
import subprocess
import sys
import time

APP_ID = "com.universalvault.app"
SEARCH_DIRS = (
    "~/Library/Developer/Xcode/UserData/Provisioning Profiles",
    "~/Library/MobileDevice/Provisioning Profiles",
)


def profiles():
    for directory in SEARCH_DIRS:
        base = os.path.expanduser(directory)
        for pattern in ("*.provisionprofile", "*.mobileprovision"):
            yield from glob.glob(os.path.join(base, pattern))


def load(path):
    result = subprocess.run(
        ["security", "cms", "-D", "-i", path], capture_output=True, check=True
    )
    return plistlib.loads(result.stdout)


def main():
    candidates = []
    for path in profiles():
        try:
            profile = load(path)
        except Exception:
            continue
        entitlements = profile.get("Entitlements") or {}
        identifier = entitlements.get("com.apple.application-identifier", "")
        if not identifier.endswith("." + APP_ID):
            continue
        if "OSX" not in (profile.get("Platform") or []):
            continue
        expires = profile.get("ExpirationDate")
        if expires and expires.timestamp() < time.time():
            continue
        prefix = identifier[: -len(APP_ID)]
        candidates.append((expires.timestamp() if expires else 0, path, prefix))
    if not candidates:
        return 1
    _, path, prefix = max(candidates)
    print(f"{path}\t{prefix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
