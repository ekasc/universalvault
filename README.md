# Universal Vault

Native macOS utility for storing arbitrary structured personal information and inserting individual values into text fields across macOS.

## Build

Requirements: macOS 26+, Xcode 27 toolchain, Swift 6.2.

```sh
cd UniversalVault
swift build
swift test
```

Run the built application:

```sh
.build/debug/UniversalVault
```

The app runs as a menu-bar utility.

## Setup and permissions

1. Launch the app. It appears in the menu bar.
2. Choose "Open Vault" -> "Create Vault" (first launch). Native user-presence authentication (Touch ID/passcode) is required.
3. Open Vault, create items and fields.

Accessibility permission is required for cross-application insertion. When first invoking quick fill, macOS prompts or System Settings > Privacy & Security > Accessibility. Enable Universal Vault.

Default shortcut: Control+Option+V. Change in a future build.

## Usage

- Open vault window from menu bar.
- Create items, add custom fields, set sensitivity.
- Focus a text field in any app, press Control+Option+V, search, Enter to insert.

## Distribution

Signed/notarized bundle packaging should use `xcodebuild` with a proper Xcode project or `swift build` + manual bundle. Notarization credentials are not configured in this repository.

Sensitive values are not written to logs; backup passphrases are used only in memory.
