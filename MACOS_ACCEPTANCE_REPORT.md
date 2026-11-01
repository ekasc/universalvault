# UniversalVault macOS Acceptance Report

Current status: `COMPLETION_REPORT.md` supersedes the historical blocked results below. Isolated native controls, Unicode editing, masked previews, both insertion strategies, cancellation, and real backup export now have runtime evidence. Vault creation and unlock with real Touch ID and data-protection Keychain user-presence access control passed on 2026-10-25 with the signed build. VoiceOver, third-party compatibility, and production notarization still need acceptance.

Commit: `f24167f` (`repair/security-reliability`)
macOS: 27.2 (build 26B5101f)
Machine: Mac14,2 (MacBook Air M2)
Xcode toolchain: installed local toolchain, Swift 6.2

## Automated and build verification

The passes below distinguish historical launches, automated logic checks, and native interaction checks that have not run.

| Test | Result | Expected | Observed | Evidence |
|---|---|---|---|---|
| Swift build | PASS | `swift build` succeeds | `Build complete! (5.18 sec)` | Terminal output |
| Unit tests | PASS | 15 automated tests pass | 11 SecurityTests + 4 CoreTests pass | Terminal output |
| Ad-hoc `.app` packaging | PASS | Debug bundle builds and is ad-hoc signed | `.build/UniversalVault.app` produced by `scripts/build-app.sh debug` | Terminal output |
| Cold application launch | PASS locally | App launches from bundle | `.build/UniversalVault.app/Contents/MacOS/UniversalVault` remains running and exposes its accessory menu | Terminal output, process listing |

The initial launch crash in `PalettePanelController.init` was fixed by replacing `NSHostingController` content-view attachment with `NSHostingView` before launching the app. This is an observed runtime fix, not only a static source check.

### Second pass

Commit: working tree on `repair/security-reliability` (uncommitted changes).

| Test | Result | Expected | Observed | Evidence |
|---|---|---|---|---|
| Swift build | PASS | `swift build` succeeds | `Build complete!` with no errors or warnings from changed files | Terminal output |
| Unit tests | PASS | All automated tests pass | 35 tests: 17 CoreTests + 18 SecurityTests, 0 failures | Terminal output |
| New tests discriminate | PASS | Tests added for a fix fail if the fix is reverted | `testMutateNotifiesObservers` and `testEscapeIsNotRecordableAsAShortcut` were both run against the un-fixed code and both failed | Terminal output |
| Ad-hoc `.app` packaging | PASS | Debug bundle builds and is ad-hoc signed | `.build/UniversalVault.app`, signature `adhoc`, identifier `com.universalvault.app`, `Info.plist` lints clean | `codesign -dv`, `plutil -lint` |
| Global shortcut recorder | BLOCKED | Recording a new chord re-registers it and survives relaunch | Not executed interactively | Requires a live session |
| Palette keyboard contract | BLOCKED | ↑↓ navigate, ↩ inserts, Esc closes, in the single `NSPanel` | Not executed interactively | Requires a live session |
| Vault creation, signed build | PASS | Touch ID grants creation, the window leaves "No vault yet", and Keychain holds the key | Vault browser appeared; `vault.uv` written (`0600`, directory `0700`); no Keychain errors logged | Interactive session, 2026-10-25 |
| Vault window re-render on unlock | PASS | Window leaves the "Vault locked" state after a successful unlock | Unlocked with one Touch ID prompt after the authentication context was reused for the Keychain read | Interactive session, 2026-10-25 |
| Shortcut registration fallback | BLOCKED | A contesting app causes the previous chord to be restored and reported | Not executed; no test covers Carbon registration failure | Requires a live session and a second app holding the chord |
| Vault window: sidebar scope | BLOCKED | Selecting a category or profile filters the item list; counts match | Not executed | Requires a window |
| Vault window: category lifecycle | BLOCKED | Create, nest, rename and delete a category; subcategories move up, items survive | Not executed | Requires a window and Touch ID |
| Vault window: editor per item | BLOCKED | Switching items shows the newly selected item, not the previous one | Not executed | Requires a window and Touch ID |
| Vault window: accessibility | BLOCKED | Controls expose a role and a name; selection is announced | Not executed; static review only, and the heuristic audit produced no true findings | Requires a window and VoiceOver |
| Quick Fill from the menu bar | BLOCKED | Palette opens and reports no target rather than inserting into UniversalVault | Not executed | Requires a window |

The `AppState` → `VaultSession` change-notification forwarding fixed in this pass
is the kind of defect that only an interactive session can confirm end to end;
the automated tests assert the underlying session state, not the SwiftUI
re-render.

### Third pass: GUI source and save safety

All changes remain uncommitted. No app window was opened during this pass. No existing app process was stopped, and no user vault or Keychain item was changed.

| Test | Result | Observed | Evidence |
|---|---|---|---|
| Debug build | PASS | `swift build` succeeds | Terminal output |
| Release build | PASS | `swift build -c release` succeeds | `.build/gui-verification/release-build.log` |
| Automated tests | PASS | 101 tests, comprising 75 CoreTests and 26 SecurityTests | `.build/gui-verification/tests.log` |
| Import conflict, cleared-name, and storage commit regression tests | PASS | Reintroducing faults in an isolated source copy produces four assertion failures across three tests | `.build/gui-verification/discrimination.log` |
| Encrypted persistence | PASS | Valid fields survive a cleared title; a rejected edit leaves encrypted bytes unchanged; returned category identity survives unlock | `SessionTests` with temporary storage and in-memory keys |
| Storage permissions | PASS | Preparation failure preserves old bytes and removes temporary data; replacement retains 0600 permissions; no throwing permission check follows commit | `StorageTests` with injected permission failures |
| Imported metadata representation | PASS | Commas, quotes, whitespace, empty strings, and Unicode round-trip without splitting stored tags or aliases | `CommaSeparatedValuesTests` |
| Stale deletion checks | PASS for domain/session logic | Changed snapshots are rejected; successful import advances generation, failed import does not | `VaultEditingTests`, `SessionTests`; dialog dismissal remains untested |
| Failed name-entry save | BLOCKED | Sheet now awaits persistence, but failure retention has not been exercised in a window | Desktop permission required |
| Final-source app packaging | NOT RUN | Earlier ad-hoc bundle predates review corrections | No current-bundle claim |
| Rendered three-column layout | BLOCKED | No screenshot of the current interface | Desktop permission required |
| Editor interaction | BLOCKED | Rapid edits/reverts, reload after import, type changes, numeric entry, tags, aliases, and custom date entry not exercised in a window | Desktop permission required |
| Palette keys and repeated presentation | BLOCKED | Single-step arrows, Return, Escape, and focus restoration not exercised | Desktop permission required |
| VoiceOver and contrast | BLOCKED | Names and selection traits inspected in source, not observed through native accessibility or rendered output | Human acceptance required |

### Fourth pass: macOS design guidelines

No desktop windows were opened. No git commands, process stops, authentication interactions, or user vault and Keychain changes occurred. Test vaults used disposable storage and in-memory keys. The test temporary directory was removed after the run.

| Check | Result | Evidence and limits |
|---|---|---|
| Debug build | PASS | `.build/gui-verification/hig-debug-build.log` |
| Focused browser and edit tests | PASS | 53 tests, 0 failures; `.build/gui-verification/hig-focused-tests.log` |
| Full automated suite | PASS | 75 CoreTests and 26 SecurityTests, 0 failures; `.build/gui-verification/hig-tests.log` |
| Release build | PASS | `.build/gui-verification/hig-release-build.log` |
| Standard menus and Settings | BLOCKED | Commands, Settings scene, and SettingsLink compile. Menu presence, shortcuts, focus routing, and disabled state in sheets, Settings, and Quick Fill need a live check. |
| Activation policy | BLOCKED | Regular mode while main windows are tracked, accessory mode after last close. Verify close, reopen, minimize, Settings, Welcome, and palette-only operation. |
| Toolbar | BLOCKED | Verify toolbar search focus with Cmd+F, CRUD controls, customization, restore defaults, and commands after hiding toolbar items. |
| Window and sidebar restoration | BLOCKED | Verify freely resizing Vault and Quick Fill, full screen and tiling, saved window frames, and sidebar visibility after reopen and relaunch. |
| Editor layout | BLOCKED | Verify type and sensitivity controls at minimum window size, long labels, and both appearances. |
| Native accessibility | BLOCKED | VoiceOver names, selected rows, keyboard focus order, Increase Contrast, Reduce Transparency, and Bold Text require native evidence. |
| Structural Undo | NOT IMPLEMENTED | Deleting an item, field, category, or profile cannot be undone. Destructive confirmation does not satisfy Undo. |
| Other guideline gaps | NOT IMPLEMENTED | Collapsible category hierarchy, drag reordering, multi-selection, and multiple vault browsing windows. |

Luna's sixth source review identified that a scene-wide Delete Item action could intercept Cmd+Delete during text editing. Delete Item now uses a list-local focused value. This correction has not been exercised in a native window. Verify Cmd+Delete in the title, each field editor, search, a name-entry sheet, and Quick Fill, then verify that list focus enables item deletion with confirmation.

Spotlight indexing and general sharing of vault content were not added because they could expose private data. No full HIG-compliance or GUI-completion claim follows from these builds and tests.

## Interactive acceptance tests

All interactive tests are `BLOCKED` from this automated session. The local system did not permit automated operation of Touch ID or complete reliable GUI control of the transient menu-bar palette. Required steps still need to be run by the human owner in a signed-in interactive macOS session.

| Test | Result | Expected | Observed | Evidence |
|---|---|---|---|---|
| 1. Launch and permissions | BLOCKED | App launches; Accessibility permission can be granted normally | App launches locally; interactive TCC permission approval not performed | Terminal output, no TCC automation |
| 2. Global shortcut | BLOCKED | Control+Option+V opens a focused, searchable palette from TextEdit | Not executed interactively | Human input required |
| 3. Basic insertion | BLOCKED | Correct synthetic text inserted at the caret, unrelated content preserved | Not executed | Human input required |
| 4. Unicode and multiline | BLOCKED | `Café 日本語 🚀`, line breaks and selection replacement handled | Not executed | Human input required |
| 5. Focus-switch safety | BLOCKED | Input/application changes cancel unintended insertion | Not executed | Human input required |
| 6. Authentication cancellation | BLOCKED | Touch ID cancellation and palette dismissal release no value | Not executed | Human approval required |
| 7. Long-text cancellation | BLOCKED | Dispatch stops on cancellation; partial safely reported | Not executed | Human input required |
| 8. Browser compatibility | BLOCKED | Local Safari/Chrome fixture inputs receive correct values and events | Not executed | Human input required |
| 9. Lock and recovery | BLOCKED | Sleep/lock/restart protect data and existing data remains accessible | Not executed | Human input required |
| 10. Encrypted backup | BLOCKED | Synthetic backup exports, imports, and restores exactly | Not executed | Human input required |

## Required human completion steps

1. Ensure no existing personal vault is at `~/Library/Application Support/UniversalVault`.
2. Run `./scripts/build-app.sh debug`.
3. Run `open .build/UniversalVault.app`.
4. Grant UniversalVault Accessibility permission through System Settings when prompted. Do not modify TCC databases.
5. Create a vault and add the listed synthetic fields.
6. Run TextEdit based on Test A and the focus safety, cancellation, Unicode, multiline, and long-text acceptance items.
7. Exercise category/profile creation, rename, and deletion. Confirm items survive deletion and sidebar scope resets after import. Switch items, clear a required name, edit another field, and confirm the field persists. Check rapid edits followed by a revert, tags, aliases, numeric input, secret sensitivity, and custom date patterns. Import a different item with the same identity while its editor is open and confirm that a stale draft cannot overwrite it.
8. Record a new global shortcut in Settings, confirm the old chord stops working, quit, relaunch, and confirm the new chord still opens the palette. Then attempt to record a chord already used by another app and confirm the previous chord is restored.
9. Run the local HTML fixture in Safari and Chrome if installed.
10. Exercise lock, sleep, unlock, restart, export and restore with an isolated vault directory, using synthetic values only.

Do not use real passport numbers, payment-card numbers, or personal identity data. Do not overwrite an existing vault or Keychain item.

## Remaining blockers outside automated coverage

- Interactive Accessibility permission approval is required.
- Touch ID approval for vault unlock, and therefore the vault window's
  transition out of the locked state, is required.
- The global shortcut recorder and the palette keyboard contract require a live
  session.
- Long-text, browser, lock/recovery, and backup tests were not executed.
- Production signing, notarization, and entitlement review remain future work.
- There are no GitHub Actions runs or commit statuses for this branch. Verification remains local.
