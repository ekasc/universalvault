# Universal Vault

Native macOS utility for storing arbitrary structured personal information and inserting individual values into text fields across macOS.

## Build

Requirements: macOS 26+, Xcode 27 toolchain, Swift 6.2.

```sh
swift build
swift test
```

Run a menu-bar build (builds, bundles, ad-hoc signs, launches):

```sh
./Scripts/run.sh
```

Or run the bare binary during development:

```sh
.build/debug/UniversalVault
```

The scripted bundle is preferable for real use: a stable bundle identifier keeps the Accessibility and Keychain identity consistent across rebuilds.

## Setup and permissions

1. Launch the app. It appears in the menu bar.
2. Choose "Open Vault" -> "Create Vault" (first launch). Native user-presence authentication (Touch ID/passcode) is required.
3. Open Vault, create items and fields.

Accessibility permission is required for cross-application insertion. When first invoking quick fill, macOS prompts or System Settings > Privacy & Security > Accessibility. Enable Universal Vault.

Default shortcut: Control+Option+V. Change in a future build.

## Usage

The normal flow is one shortcut, one Touch ID prompt, one Enter:

1. Click into any text field in any app.
2. Press Control+Option+V.
3. If the vault is locked, authenticate once. The Keychain item is the only gate; there is no second password prompt.
4. The palette opens attached to the field you are in. Type to filter, then click a row (or use arrows and Return).

The palette is a non-activating panel, so the app you are filling normally never loses focus. Press Control+Option+V again or Escape to dismiss it.

The menu bar item offers the same Quick Fill action, plus Open Vault (create/edit items and fields) and Lock Vault.

## Distribution

Signed/notarized bundle packaging should use `xcodebuild` with a proper Xcode project or `swift build` + manual bundle. Notarization credentials are not configured in this repository.

Sensitive values are not written to logs; backup passphrases are used only in memory.
