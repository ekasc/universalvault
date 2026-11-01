# Architecture

## Modules

- Core: domain models, search, templates, validation, structural editing (`VaultEditing`), sidebar/list filtering and ordering (`VaultBrowser`). No Apple security dependencies.
- VaultSecurity: storage, Keychain access, user-presence authentication, encryption, session management.
- Insertion: Accessibility permission, focus capture, insertion engine using AX and controlled keyboard fallback.
- App: SwiftUI menu-bar app, vault window, quick-fill palette, global shortcut, settings, packaging inputs.

## Data flow

`VaultPayload` (Codable) -> JSON -> AES-GCM (CryptoKit) -> file under `Application Support/UniversalVault/vault.uv`. The 256-bit data-encryption key lives in the data-protection Keychain without a user-presence requirement, so the vault opens at launch. Items the user marks protected keep their fields sealed with a second AES-GCM layer under a `.userPresence` key; while that key is not held, `VaultItem.sealedFields` holds the ciphertext and `fields` is empty. Both Keychain items require the embedded `com.universalvault.app` Mac Team provisioning profile and its `keychain-access-groups` entitlement. `VaultSession` exposes its decrypted payload only while unlocked. Canceled backup computation can retain a private snapshot until its KDF returns, but generation checks prevent a stale commit. Secure memory cleanup is best-effort under Swift ARC.

Search runs over the in-memory decrypted payload and is cleared by the lock path. Search results contain field references but value previews are masked for sensitive and critical fields in the palette UI. Previews for non-sensitive fields appear only when the vault setting enables them.

## Quick-fill presentation

The palette is a single `NSPanel` (`PalettePanelController`) hosting an
`NSHostingView`. There is no second SwiftUI window for the palette: one
presentation path means one place where focus, dismissal and lock-driven hiding
are handled.

## Global shortcut

The shortcut is a `HotKeyShortcut` (virtual key code plus a Carbon-compatible
modifier mask) persisted in `UserDefaults`, not in the vault. It must be
available while the vault is locked so the app can report a locked vault instead
of appearing unresponsive. Registration is attempted at launch; if the stored
chord is unavailable, the default is restored and the user is told.

## Vault window

Two panes: the item list and the record editor. `VaultBrowser` (Core) owns the
rules — which items a scope selects, how they are ordered, how a category tree
flattens, and how many items each category holds — so the views only render.
`VaultEditing` (Core) owns structural change: what happens to subcategories and
items when a category is deleted, and which sort order a new sibling takes.

`VaultSelection` (All Items / a category / a profile) is the single source of
truth for scope. The list header renders it as a menu and owns category and
profile management, so the window needs no third column. New items are filed
into the scope being viewed.

The editor is created per item and the parent applies `.id(itemID)`. SwiftUI
would otherwise reuse the view for a different item, `onAppear` would not fire
again, and the stale editor would save the previous item's values over the new
one.

Each editor queues its drafts in order. `VaultPayload.itemForSaving` compares a draft's baseline with the current saved item when that draft runs. It rejects an item changed elsewhere and removes deleted category and profile references. Required names use their last saved values while other changes persist. No-op detection runs after the preceding save, so a rapid revert still takes effect. Reloading invalidates older queued drafts; locking changes the session generation and prevents those drafts from reaching another session.

`VaultSession.mutate` accepts a throwing edit and returns its result only after validation and encrypted storage succeed. Name-entry sheets await this result before dismissal and selection changes. Other sidebar and item-list actions use `AppState.edit`'s success callback. Storage checks permissions before replacement and preserves the temporary file's private metadata at commit.

`VaultSession.replaceContents` changes the session generation after a successful import. Delete confirmations capture that generation and the object snapshot, preventing a stale action from deleting replacement data. Tags and aliases use `CommaSeparatedValues` to preserve imported strings when displayed as editable text.

## Native commands and windows

`VaultCommands` adds File, Edit, Vault, and Help commands alongside SwiftUI's standard application menus. Sidebar and toolbar commands use SwiftUI's built-in command groups. Item, sidebar, and editor views publish typed actions through focused scene values. A missing action disables its menu item. Delete Item uses a list-local focused value instead of a scene value, so text fields do not publish that command. Menu commands call the same persistence paths as the controls.

The Settings scene supplies the standard Settings command and `SettingsLink`. `MainWindowBehavior` attaches to the Vault, Settings, and Welcome windows without creating another window or replacing SwiftUI's window delegate. `AppWindowRegistry` tracks those windows until their close notifications. It selects regular activation while any is open and accessory activation otherwise. Quick Fill stays on its separate nonactivating panel path. Window frame autosave names are stable; sidebar visibility uses `SceneStorage`.

Item controls use an identified, customizable toolbar and native toolbar search. Field labels and type controls occupy separate rows so the detail column has fewer fixed-width controls. Quick Fill content expands with the panel, and placement uses its current frame size.

These are source-level arrangements. Focused command routing, activation transitions, customization, and restored geometry require native acceptance.

## Insertion flow

1. Capture the focused Accessibility element and its application before showing the palette, or the editable element under a right-click through Accessibility hit-testing.
2. Validate the same element, process, application identity, capabilities, and session before dispatch.
3. Attempt Accessibility selected-text insertion only when the field's value actually changes; web views accept the attribute and ignore it.
4. Otherwise activate the target, place the caret at the click point, and type through the HID event stream. Events posted directly to a pid are dropped by Chromium.
5. Confirm typed insertion by polling the field value for a short window.
6. Return structured outcomes: verified, unverified/dispatched, canceled, rejected, failed, or partial.
7. Never use clipboard fallback or target another input.

## Locking

`VaultSession` locks on explicit logout, inactivity, system sleep, screen-lock notification, and application termination. Any lock changes the session generation, invalidating asynchronous insertion work and clearing palette/search/editor state.

## Packaging

`scripts/build-app.sh` builds an executable with Swift Package Manager and assembles an accessory app bundle with a stable bundle identifier, Info.plist, and ad-hoc signature. It is not a production distribution pipeline.

## Open limitations

- Real insertion compatibility is listed in `COMPATIBILITY.md`.
- Third-party compatibility and real authentication still require human acceptance.

## Completion changes

`VaultPayload.validated()` checks complete payloads at decryption, import, replacement, and mutation boundaries. It preserves legacy text-backed typed fields without discarding their values. Dates can be explicitly empty.

`VaultSession` tracks the ciphertext it loaded. `FileSystemVaultStorage.write(_:expected:)` compares and replaces under a stable advisory lock. A stale writer receives a conflict without changing its payload or the saved file. Authentication request IDs reject work superseded by lock, cancellation, or a newer request.

`InsertionAuthorization` binds a field snapshot, item identity, sensitive-field policy, and session generation. AppState checks that authorization after authentication and passes it through every insertion dispatch check. Keyboard chunks contain at most 20 UTF-16 units and never split a surrogate pair.

Undo and redo retain at most 30 unlocked-session payload snapshots. Successful undo persists through the same compare-and-swap boundary and advances generation, invalidating pending editors and insertions. Lock, unlock, recovery, and backup replacement clear history.

Recovery validates an independent encrypted backup, authenticates, archives the existing ciphertext, and then commits replacement data. Missing keys can be created, but existing keys are never deleted. BackupTransferView runs KDF and bounded file-read work off the main actor, then checks generation before replacement or export.

Debug-only native verification uses the real views and actions with isolated storage and synthetic authentication. A separate native target process verifies Accessibility and keyboard insertion without touching another user's application. Release verification flags exit before the production storage path. See `scripts/verify.sh` and `COMPLETION_REPORT.md`.
