# UniversalVault

Native macOS menu-bar utility for storing arbitrary structured personal information and inserting individual saved values into text fields across macOS.

## Build

Requirements: macOS 26+, Swift 6.2 toolchain (Xcode on macOS). The deployment
target is declared once in `Package.swift` (`.macOS(.v26)`) and mirrored in
`Packaging/Info.plist`.

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

The bundle is signed with your `Apple Development` identity and the installed
`Mac Team Provisioning Profile: com.universalvault.app`. The data-protection
Keychain, and the user-presence access control on the protected-item key, need
that profile and its `keychain-access-groups` entitlement: an ad-hoc build
cannot create a vault key and reports a signing error. Create or renew the
profile with:

```sh
./scripts/provision.sh
```

Personal Team profiles expire after seven days. After expiry, run
`scripts/provision.sh` again and rebuild.

The app stays in the menu bar. Click the icon for the management menu: Open Vault, lock/unlock, Welcome, Settings and Quit. Opening Vault, Settings, or Welcome also shows its Dock entry and standard application menu. Closing the last of those windows returns to menu-bar-only mode.

## First run

1. Launch the app; it appears in the menu bar.
2. Right-click the menu bar icon and choose "Welcome…" for what the app does and
   the Accessibility permission request, or choose "Open Vault" -> "Create
   Vault". Creating and opening the vault need no authentication; only items you
   mark protected ask for Touch ID.
3. Add items and fields from the vault window. Templates are available from the list header's **New** menu. Each item can be filed into a category and a profile created from the same menu.

Accessibility permission is required for cross-application insertion. macOS prompts or uses System Settings > Privacy & Security > Accessibility. UniversalVault cannot bypass or modify permission state.

Default shortcut: Control+Option+V. Change it in Settings under "Global
Shortcut"; the choice persists across launches and is re-registered at startup.
If the chosen chord is already claimed by another application the change is
rejected and the previous shortcut is restored.

## Usage

The vault window is two panes: the item list for the current scope, and the
record editor. The scope itself — **All Items**, a category, or a profile — is a
menu at the top of the list, so there is no separate navigation column.

- Right-click the menu bar icon and choose Open Vault.
- Create items, add arbitrary fields, set field types and sensitivity.
- Secret fields stay at least `sensitive`. Type changes preserve compatible values and reject conversions that would discard a value.
- Edits save automatically. Clearing a required title, key, or label keeps its saved name while other changes continue to save. A banner identifies the unfinished name.
- If an import or another editor changes the item, saving stops and reports the conflict. "Reload saved item" discards the unfinished draft and loads the stored copy.
- Items carry an icon, tags, a category and a profile. Categories can nest; a
  subcategory is created from a category's context menu.
- Separate tags and aliases with commas. Quote a value containing a comma, such as `"last, first"`. Imported values use this quoted representation automatically.
- Date fields choose how the value is inserted: ISO, local short, or a custom
  Unicode date pattern.
- Date fields start empty. Turn on "Set date" before choosing a date.
- Templates create an item already filed in the scope you are viewing.
- Deleting a category never deletes items. Its subcategories move up one level
  and its items become uncategorized; the confirmation says so before it runs.
- **Right-click an editable field** in any app to choose a vault field from a menu at the cursor. While the vault is unlocked, this menu replaces the app's own context menu for that click; Cut, Copy, Paste and Select All are forwarded to the app, and UniversalVault never touches the clipboard itself.
- Or focus a supported text field, press Control+Option+V, search, then press Enter. Press the shortcut again to close Quick Fill. It is also in the Vault menu if global shortcut registration fails.
- Sensitive and critical values are masked in search results, editors, notifications, and errors.
- Mark an item as protected from its **Touch ID** control. Its fields are sealed
  with a second key that only Touch ID releases, so a locked item is unreadable
  rather than hidden: it is absent from search and quick fill until you unlock
  it, and the vault file never contains those values in plaintext.
- Protected items close on sleep, screen lock, or the inactivity timeout; the
  vault itself stays open. Signing out of the Mac or quitting the app closes the
  whole vault. Use Vault > Lock to close everything immediately.
- Critical fields always require fresh user-presence authentication; sensitive fields honor the configured setting.
- Settings exposes the protected-item timeout, sensitive insertion policy, value
  previews, the global shortcut, and encrypted backup import/export.
- Restore encrypted backups from Settings or from the locked vault screen. Recovery preserves any existing encrypted file in a private recovery archive before replacement.
- Drag items to reorder them, or use Move Up and Move Down in their context menu. Each field has an accessible ordering menu. Category disclosure buttons collapse their descendants.
- The Vault menu provides undo and redo for the last 30 vault changes. Locking, reopening, or replacing the vault clears this in-memory history.
- Competing sessions cannot silently overwrite saved changes. On a conflict, retain any unfinished values, then lock and unlock to reload the saved vault.
- Value previews in the palette are off by default; sensitive and critical
  values stay masked even when previews are on.
- No clipboard fallback is used.

## Keyboard and assistive technology

The application menu adds these shortcuts. They still need interactive verification.

| Action | Shortcut |
|---|---|
| Open Vault | Cmd+O |
| New Item | Cmd+N |
| New Category | Cmd+Shift+N |
| New Profile | Cmd+Option+N |
| Find Items | Cmd+F |
| Duplicate Item | Cmd+D |
| Delete Item, with confirmation and list focus | Cmd+Delete |
| Rename Category or Profile | Cmd+Shift+R |
| Add Field | Cmd+Shift+A |
| Quick Fill within the app | Cmd+Shift+F |
| Lock or Unlock Vault | Cmd+Shift+L |
| Settings | Cmd+, |
| Help | Cmd+? |
| Undo vault change | Cmd+Option+Z |
| Redo vault change | Cmd+Option+Shift+Z |

Item actions are in the context menu and the menu bar; the toolbar carries search only. Sidebar visibility is stored per scene. The Quick Fill panel resizes with its content.

- The item list is a standard list, so it supports arrow keys, type-select and the accessibility APIs.
- Icon-only controls have accessible names. Selected rows include selection traits, and decorative row icons are hidden from assistive technology.
- Create categories and profiles from the list header's **New** menu. Rename or delete the current scope from the scope menu. When a category is the current scope, **New** creates a subcategory of it.

Standard text undo keeps Cmd+Z. Vault history has separate shortcuts so it does not intercept text editing. Multi-selection and multiple vault browsing windows are not implemented.

Native verification exercises controls, Unicode editing, lock transitions, and insertion into an isolated native fixture. VoiceOver, real authentication, third-party compatibility, and full menu dispatch still need human acceptance. See `COMPLETION_REPORT.md` for current evidence.

## Distribution

`scripts/build-app.sh [release|debug]` builds the bundle, embeds the
`com.universalvault.app` provisioning profile, and signs with the first
`Apple Development` identity. Override the identity with `CODESIGN_IDENTITY`.
`scripts/provision.sh` creates or renews the profile through Xcode automatic
signing, and `scripts/find-profile.py` reports the profile that would be used.
Without a usable profile the script falls back to ad-hoc signing, and the app
refuses vault creation with an explicit signing error instead of a Keychain
failure code.

No notarization or Developer ID identity is configured. Production distribution
requires your own Apple signing identity, notarization, and review of
entitlements.

## Verification

Run the headless checks with `bash scripts/verify.sh`. To include native windows, run `bash scripts/verify.sh --native`. Native checks use synthetic data, an in-memory key, and disposable storage. They do not use the personal vault or real Keychain. They reuse existing Accessibility permission without requesting or modifying it.

The native runner launches one verification window at a time, including a separate insertion-fixture process. Its process group has a 90-second lifetime limit. Screenshots and results are written under `.build/native-verification/`. Release builds reject verification flags before accessing storage.

## Agents

Agents can read a deliberately small slice of the vault and nothing else:

```sh
.build/UniversalVault.app/Contents/MacOS/UniversalVault --about-me
```

It prints JSON (`format`, `version`, `vaultUpdatedAt`, `generatedAt`, `items`) and
exits. Only items marked **AGENTS** in their item editor contribute, and only
fields that are neither sensitive nor critical. A protected item is never
included, whatever its flag says, and the command cannot read the sealed key.

The command never prompts: if the vault key still needs its one-time migration it
fails with a message instead of opening a Touch ID dialog. Exit status is 0 with
an empty `items` array when nothing is shared, and 1 with a message on stderr when
the vault cannot be opened.

Filtering is enforced by the command, not by encryption. Sensitive fields sit in
the same decrypted payload as everything else, so a modified build could print
them; what it cannot do is open protected items, which need the sensitive key.
Store credentials in secret-typed fields or protected items.

## Privacy and security

- Vault data is AES-GCM encrypted locally. The 256-bit data-encryption key is stored in the data-protection Keychain without a user-presence requirement, which is what lets the app open at launch. Items you mark protected are sealed a second time with AES-GCM under a separate key that the Keychain releases only after user presence, so those values are unreadable without Touch ID even with the vault open. Both items are signed with the `com.universalvault.app` Mac Team provisioning profile and its `keychain-access-groups` entitlement.
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
- `COMPLETION_REPORT.md`: current implementation and verification status.
