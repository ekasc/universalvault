# UniversalVault

Native macOS menu-bar utility for storing arbitrary structured personal information and inserting individual saved values into text fields across macOS.

## Build

Requirements: macOS 14+, Swift 6.2 toolchain (Xcode on macOS).

```sh
cd UniversalVault
swift build
swift test
```

Run the built executable:

```sh
.build/debug/UniversalVault
```

Build a reproducible native `.app` bundle:

```sh
./scripts/build-app.sh
open .build/UniversalVault.app
```

The app runs as a menu-bar/accessory application.

## First run

1. Launch the app; it appears in the menu bar.
2. Choose "Open Vault" -> "Create Vault". Native user-presence authentication is required.
3. Add items and fields from the vault window. Templates are available from the sidebar `+` menu.

Accessibility permission is required for cross-application insertion. macOS prompts or uses System Settings > Privacy & Security > Accessibility. UniversalVault cannot bypass or modify permission state.

Default shortcut: Control+Option+V. Change shortcut persistently is not yet implemented.

## Usage

- Open the vault window from the menu bar.
- Create items, add arbitrary fields, set field types and sensitivity.
- Secret fields raise sensitivity to at least `sensitive`.
- Focus a supported text field in any app, press Control+Option+V, search, then press Enter to insert.
- Sensitive and critical values are masked in search results, editors, notifications, and errors.
- Critical fields always require fresh user-presence authentication; sensitive fields honor the configured setting.
- Settings exposes inactivity timeout, sensitive insertion policy, value previews, and encrypted backup import/export.
- No clipboard fallback is used.

## Distribution

`scripts/build-app.sh [release|debug]` creates an ad-hoc-signed `.app` bundle with a stable bundle identifier and Info.plist.

No signing, notarization, or developer-team credentials are configured. Production distribution requires your own Apple signing identity, notarization, and review of entitlements. Keychain continuity is improved by keeping the bundle identifier stable, but ad-hoc signing should not be treated as migration-grade identity.

## Privacy and security

- Vault data is AES-GCM encrypted locally; the 256-bit data-encryption key is stored in Keychain with user-presence access control.
- Backups are encrypted backups using PBKDF2-HMAC-SHA256 with an independent salt and authenticated metadata; exports require at least 12 characters.
- Sensitive values are not written to logs; backup passphrases are used only in memory.
- Memory zeroization is best-effort under Swift ARC and is not guaranteed.
- The app does not implement cloud sync, remote APIs, browser extensions, or AI features.

## Documentation

- `ARCHITECTURE.md`: module and data-flow design.
- `SECURITY.md`: threat model, controls, and evidence status.
- `COMPATIBILITY.md`: insertion compatibility status.
- `IMPLEMENTATION_REPORT.md`: repaired defects and remaining work.
- `SECURITY_REGRESSION_MATRIX.md`: regression matrix for the security requirements.
