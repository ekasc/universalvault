# Implementation Report

Current status: `COMPLETION_REPORT.md` supersedes the historical gaps below. Undo, ordering, category collapse, recovery, cross-process conflicts, and isolated native verification have since been implemented.

Branch: `repair/security-reliability`

## Fixed and verified

- Palette panel controller is retained by `AppState`, so native quick-fill presentation persists.
- Vault creation no longer deletes existing/orphaned keys as cleanup; a Keychain key without a vault now requires recovery instead of deletion.
- Failed vault writes do not delete the new key unless no vault exists.
- `requirePresence()` propagates an authentication result of `false`.
- Backup import no longer applies changes directly; it validates, stages, and requires explicit replacement.
- Secure backup settings work captures passphrases locally before clearing UI state, avoiding empty-passphrase races.
- Backup import validates PBKDF2 iteration bounds.
- Keyboard insertion revalidates focus before every chunk and distinguishes partial delivery.
- Editor saves are serialized to reduce stale/order races.
- Menu bar no longer opens a redundant native palette window.
- Storage startup failure shows an actionable alert and exits instead of crashing.
- Vault creation cannot overwrite an existing vault or key; creation rejects existing vault/key and reports distinguishable states.
- Vault creation and unlock now reject an authentication result of `false`, even when no error is thrown.
- Paladin transaction dismissal now invalidates in-flight insertion transactions while authorized insertion hides the palette without canceling them.
- Keyboard insertion dispatch is asynchronous and no longer blocks the main thread for each chunk.
- `SettingsView` clears retained imported backup state when the vault locks.
- Random-number generation failure fails closed.
- Tampered ciphertext and unsupported metadata versions fail decryption.
- Backup versioned envelope preserves metadata integrity and supports legacy import.
- Large numeric values cannot trap during `insertionText`.
- Field loading on macOS builds cleanly (Swift 6.2).
- `.app` bundle package can be assembled and ad-hoc signed.
- Models, validation, cryptography, backup, and vault lifecycle automated tests pass.

## Fixed but not integration-tested

- Global quick-fill keyboard focus still needs interactive verification.
- System sleep, screen-lock, and termination locking on real macOS devices.
- Insertion into external applications.
- Real global shortcut behavior from arbitrary focused applications.
- Backup export/import workflow in the settings UI.
- UI behavior after lock in multi-window configurations.
- Settings-driven insensitive insertion and auto-lock behavior.

## Still blocked

- Automated Accessibility insertion tests require `AXIsProcessTrusted`, interactive TCC permission, and a live foreground target.
- Real browser insertion compatibility has not been executed.
- Real user-presence authentication behavior in production paths requires manual testing on macOS.

## Explicitly deferred

- Argon2id or another memory-hard backup KDF; retained PBKDF2 (200,000 iterations) with documented parameters.
- Undo for item deletion.
- Complete domain migration/recovery UI.
- Production signing, notarization, and entitlement review.

## Second pass: completion

Goal of this pass: no user-facing action that silently does nothing, one palette
presentation path, every shipped setting effective, and the one feature the
README labelled "not yet implemented" finished.

Fixed and covered by automated tests:

- `VaultSession.createNewVault()` and `unlock()` now record failures in
  `lastError`. Previously both buttons discarded their error with `try?`, and no
  failure path ever assigned `lastError`, so a failed unlock produced no feedback
  at all. Both states of the vault window render it: the locked state gained the
  line in this pass, the no-vault state already had it. Failure paths are covered
  by `SessionTests.testFailedCreateRecordsLastError` and
  `testFailedUnlockRecordsLastError`, plus `testErrorFromSecondCreateIsRecorded`
  for the second-create case. `testSuccessfulCreateLeavesNoError` is a guard
  against `lastError` being set on success; it does not discriminate the fix.
- `VaultPayload` is now `@Published` on `VaultSession`. `isUnlocked` and
  `sessionGeneration` do not change when an item is edited, so a pure `mutate`
  previously notified no observer and views reading `currentPayload` did not
  re-render. Covered by `SessionTests.testMutateNotifiesObservers`, which fails
  if the property stops publishing.
- The auto-lock decision moved to `AutoLock.shouldLock(...)` so the clamping and
  threshold rules are testable without a running timer. `AutoLockTests` cover
  that predicate; the session's 30-second timer that calls it is covered by
  inspection, not by a test.
- The global shortcut is configurable and persisted (`HotKeyShortcut`,
  `ShortcutPreferences` in Core; `SettingsView` -> "Global Shortcut"). Validation,
  display and persistence are covered by `ShortcutTests`. The registration
  fallback - a chord already claimed by another app, or a stored chord that has
  since become unavailable - is *not* covered by any test: it runs through
  Carbon registration, which the App target cannot exercise without a test
  target, and is listed as an interactive check instead.
- Escape was removed from the recordable key table. `validate()` accepted it
  while the recorder used it to cancel, so a stored Command-Escape chord could
  register a global Escape intercept. Covered by
  `ShortcutTests.testEscapeIsNotRecordableAsAShortcut`.
- Value previews in the palette now honour the `showValuePreviews` setting, which
  previously had no effect; sensitive and critical values stay masked regardless.
  The preview text also changed source from `storageDescription` to
  `insertionText`, so number and date fields preview the value as it will be
  inserted rather than a raw `Double` or epoch timestamp.
- `HotKeyManager` tracks `isRegistered` separately from `current`, reports when
  no chord could be registered or the previous chord could not be restored, and
  tears its Carbon handler down in an isolated `deinit`.
- Recording the already-active chord is now a no-op. It previously unregistered
  the working shortcut before attempting to re-register it, so a transient
  failure would drop a functioning shortcut and report a false conflict.
- The palette's search field re-asserts focus on each presentation rather than
  relying on `onAppear`, which is not guaranteed to fire again for the single
  long-lived `NSHostingView`.
- `SettingsView` disables the settings that require an unlocked vault instead of
  letting them fail to save, and reports the shortcut outcome in its status line.

Fixed, verified by inspection rather than by a test:

- `AppState` now forwards `VaultSession`'s `objectWillChange`. No view reading
  `appState.session.isUnlocked` could previously re-render after create, unlock
  or lock, because `AppState` observed none of the nested session's changes. The
  state-level behaviour is covered by
  `SessionTests.testLockClearsPayloadAndAdvancesGeneration`; the SwiftUI
  re-render itself is not asserted by any test in this repository.
- The palette is presented once, by `PalettePanelController`. The redundant
  `Window("Quick Fill", id: "palette")` scene and the `openWindow(id: "palette")`
  in the menu bar are gone, along with the window-title-based close loops in
  `AppState` that existed only to clean up the duplicate. The first-pass entry
  "Menu bar no longer opens a redundant native palette window" did not hold for
  the code as committed at the time; the duplicate scene was still present.
- `HotKeyManager.register` releases the previous registration first and rolls
  back the event handler if `InstallEventHandler` fails, so a failed
  registration cannot leave a half-installed shortcut.
- A debug `FileHandle.standardError.write(Data("SHOW\n"))` call in
  `PalettePanelController.show()` was removed.

Also corrected while working in these files, and declared here because neither is
part of the stated goal: the menu-bar item used `systemImage: "vault"`, which is
not a stock SF Symbol, and is now `"lock"`; and `README.md` stated a macOS 14
minimum where `Package.swift` and `Info.plist` both require macOS 26.

## Third pass: GUI completion

Goal: every modelled domain concept reachable from the interface, every state
given an empty case, and every control meeting the accessibility rules.

What the interface now exposes that the model already had:

- Categories and profiles can be created, renamed and deleted, and items filed
  into them. `VaultPayload.categories`, `VaultPayload.profiles`,
  `VaultItem.categoryID` and `VaultItem.profileID` existed before, search
  rendered a category name, and no interface could produce either of them.
- `VaultItem.icon` and `VaultItem.tags` are editable.
- `VaultField.preferredInsertFormat` is editable for date fields, as presets
  (ISO, local short, US, day first) or a custom Unicode pattern. It was modelled,
  honoured by `insertionText`, and settable from nowhere.

Structural rules, all in `VaultEditing` and covered by `VaultEditingTests`:

- Deleting a category deletes no items. Subcategories move up one level and the
  category's items become uncategorized. There is no code path by which a
  sidebar action can remove an item.
- A category whose parent id no longer resolves is shown at the root rather than
  vanishing; a cyclic parent chain terminates and stays visible.
- Duplicating an item gives the copy fresh field identities, so editing one item
  cannot write through to another.

Defects found while building the interface:

- Selecting item B while item A was open left A's values in the editor, and the
  first keystroke wrote A's content over B. The editor is now created per item
  and the parent applies `.id(itemID)`.
- Clearing a required title, label, or key blocked later field edits. The editor now saves valid edits while retaining the saved required names. A banner identifies unfinished names and offers "Reload saved item".
- Quick Fill invoked from the menu bar captured UniversalVault's own focused
  control as the insertion target. Self is now excluded, so the palette reports
  that there is no target instead of typing into the app's own window.
- The palette's list selection binding discarded every write, so the highlight
  existed only as a background colour and assistive technology could not see
  which row was current. Selection is now two-way.
- The palette filtered results only when the query changed, so a result list
  could survive a scope change that removed its contents.

Empty-state views cover an absent vault, a locked vault, no selection, no items, no search matches, and no palette results. They include accessible text, but appearance and announcements have not been verified in a native window.

Icon-only controls include accessible names, selected rows include selection traits, and decorative row icons are hidden. Palette results include sensitivity in words and an explicit Insert accessibility action. VoiceOver behavior remains unverified.

### Review corrections

- Save checks run after the previous queued save. A rapid edit followed by a revert no longer skips the revert as a premature no-op.
- `VaultPayload.itemForSaving` rejects missing items and content changed by import or another editor. Deleted category and profile assignments are removed without blocking unrelated field edits.
- Reloading invalidates pending drafts. A session-generation check prevents old drafts from writing after a lock and unlock.
- Structural edits report their result after persistence. Sidebar and item-list selection changes run only after successful storage, and category/profile errors are no longer discarded with `try?`.
- Invalid or absent sidebar scopes reset to All Items after payload changes. Category cycles remain visible as flat rows.
- Palette arrow handlers run only while search has focus. Return handling from list focus excludes the search field's submit path. Native key delivery still needs a live check.
- Custom date-pattern entry opens even when the stored format is a preset. Tags and aliases keep raw input locally so typing a comma does not erase the delimiter.
- Field bindings resolve their identity on every read and write instead of retaining an array index after deletion.
- Type changes preserve compatible values and reject incompatible conversions. Secret fields stay at least sensitive. Sensitive non-secret editor values require an explicit Show value action.
- Numeric input keeps intermediate text such as a minus sign without replacing the saved number. Nonfinite input does not persist.
- Settings skips unchanged saves, reloads after unlock/import, and interpolates backup errors correctly.
- Storage applies private permissions before replacement and uses the new file's metadata. There is no throwing permission operation after commit, and failed preparation removes the temporary file. Failure-injection tests check both paths.
- Tag and alias input uses a reversible quoted representation. Opening imported values containing commas, quotes, whitespace, or empty strings does not split or remove them.
- Successful backup replacement changes the session generation. Pending deletion confirmations capture that generation and a snapshot; import invalidates them, and changed snapshots cannot be deleted by an old confirmation.
- Name-entry sheets await persistence before dismissal. Failure keeps the entered name and displays an inline error. Item deletion clears selection only after successful persistence.

## Fourth pass: macOS commands and window behavior

- Standard File, Edit, Vault, and Help commands now expose creation, find, duplicate, delete, rename, Add Field, Quick Fill, and lock actions. SwiftUI supplies sidebar and toolbar commands. Focused scene values connect commands to the current view's actions.
- The custom Settings window became a standard Settings scene, with a SettingsLink in the menu-bar menu.
- Main windows register for frame autosave and close notifications. Their presence controls regular versus accessory activation, so editing can have a standard app menu without leaving a permanent Dock entry.
- Item actions moved from footer icons into a customizable toolbar. Search uses the native toolbar field. The item list adds selection-aware context actions and Delete-key confirmation.
- Sidebar visibility uses SceneStorage. Vault has a minimum size without a maximum. Field labels and type controls use separate rows instead of competing in one fixed-width row.
- Quick Fill content expands with its panel. Placement uses the actual panel size. Selection uses the native List highlight instead of a second translucent accent background.
- Debug and release builds pass. Focused tests pass with 53 tests; the full suite passes with 101. Logs use the `hig-` prefix in `.build/gui-verification/`.
- Luna's source review identified that a scene-wide Delete Item action could intercept Cmd+Delete during text editing. That action now uses a list-local focused value. Other item commands remain scene-wide.
- Native menu dispatch, sheet and palette command availability, window activation, restoration, keyboard behavior, screenshots, and accessibility remain unverified. The existing app bundle predates these changes.

## Known gaps left in place

- `InsertionTarget` in `Sources/Insertion/Target.swift` is unused.
- `Tests/CoreTests/ModelsTests.swift:22` carries a pre-existing
  `var`-never-mutated compiler warning.
- Six cases in `Tests/SecurityTests/CryptoTests.swift` each leak a scratch
  directory into `$TMPDIR`. The tests added in these passes clean up after
  themselves.
- Item and field reordering is not exposed; `sortOrder` is preserved and
  appended to, but there is no drag-to-reorder.
- Structural deletion has no Undo support. Category hierarchy is indented but cannot collapse. Lists do not support multi-selection, and the vault browser has one window.

## Current verification

- Debug and release builds pass with `swift build` and `swift build -c release`.
- `swift test` passes with 101 tests, comprising 75 CoreTests and 26 SecurityTests.
- New session tests confirm that rejected edits leave encrypted storage unchanged, returned identities survive an unlock, and field edits persist when the title is cleared.
- Mutation checks in an isolated source copy removed the import-conflict guard and title fallback and restored a throwing permission call after commit. All three regression tests failed, with four assertion failures. The repository source was unchanged by this check.
- Local evidence is in `.build/gui-verification/`. Temporary test vaults use in-memory keys and a disposable directory. No user vault or Keychain item was touched.
- Earlier passes assembled and ad-hoc signed `.build/UniversalVault.app`. That bundle has not been rebuilt or launched after these review corrections.
- The two tests added for the `mutate` notification and the Escape key were
  confirmed to fail against the un-fixed code before being accepted.
- The interface itself is **not** verified. `ImageRenderer` was tried as a
  headless rendering path and rejected: it draws text but renders `List`,
  `TextField` and `Picker` as unsupported placeholders, so it cannot show the
  surfaces that matter. Rendering this interface requires a real window.

## Changed documentation

- `README.md`
- `ARCHITECTURE.md`
- `SECURITY.md`
- `COMPATIBILITY.md`
- `SECURITY_REGRESSION_MATRIX.md`
- `MACOS_ACCEPTANCE_REPORT.md`
