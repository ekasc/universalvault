# Security regression matrix

Each row names a requirement, the status of its verification, and the test or script that shows it. `.build/...` paths are local output from the last run and are not in the repository.

Status values: `Verified` means an automated test or recorded build evidence covers the requirement. `Fixed (not integration-tested)` means the code does what the row says and unit tests or reading the code confirm it, but no integration or native evidence covers it. `Blocked` means the check cannot run in the available environment.

## Security hardening pass

| Requirement | Status | Evidence |
|---|---|---|
| Lock invalidates pending protected-item unlock and creation | Verified with controlled authentication | `SessionConcurrencyTests` |
| Changed field cannot reuse pending insertion authorization | Verified | `InsertionAuthorizationTests`, `AppStateTests.testFieldChangedDuringActualAuthenticationCancelsInsertion` |
| Imported secrets cannot retain normal sensitivity | Verified | `PayloadValidationTests`, `PayloadBoundaryTests` |
| Competing processes cannot silently overwrite saves | Verified | `scripts/verify-storage-processes.py` |
| Undo persists and clears on lock or replacement | Verified | `HistoryRecoveryTests` |
| Recovery preserves original encrypted bytes | Verified with synthetic keys | `HistoryRecoveryTests.testRecoveryPreservesOriginalAndRestoresIndependentBackup` |
| Native backup export writes a decryptable private file | Verified with synthetic authentication | `.build/native-verification/result.json` |
| Native recovery preserves the original encrypted file and restores the backup | Verified with synthetic authentication | `.build/native-verification/result.json`, `13-recovered-window.png` |
| Lock command dispatches through the application menu | Observed once. Not in the repeatable gate | Menu actions require an open, validated menu |
| Replace-while-unlocked clears undo and redo history | Verified with synthetic authentication | `.build/native-verification/result.json` |
| Category creation persists through the real sidebar menu and sheet | Verified | `.build/native-verification/14-category-created-window.png` |
| A stale editor draft cannot overwrite an item changed elsewhere | Verified in a real editor | `staleEditorConflict` in `.build/native-verification/result.json` |
| Toolbar search filters the item list and reports no matches | Verified | `.build/native-verification/16-search-no-match-window.png` |
| Keyboard insertion preserves Unicode and stops after lock | Verified against native fixture | `.build/native-verification/result.json`, `UnicodeEventChunksTests` |
| Release builds reject synthetic verification before storage access | Verified | `.build/verification/release-isolation.log` |

## Vault, insertion, and editing requirements

| Requirement | Status | Evidence |
|---|---|---|
| Cannot overwrite existing vault during creation | Verified | `CryptoTests.testCreateVaultTwiceThrows` |
| Existing key survives failed vault initialization | Fixed (not integration-tested) | Creation rolls back a new key when the write fails. Not simulated exhaustively. |
| Keychain failure does not trigger new key generation | Fixed (not integration-tested) | `keyExists` errors surface. No path generates a key automatically. |
| Failed migration preserves old data | Fixed (not integration-tested) | No migration command is exposed for destructive rotation. |
| Tampered ciphertext cannot decrypt | Verified | `CryptoTests.testTamper` |
| Tampered security metadata cannot be accepted | Verified | `CryptoTests.testUnsupportedVersion` |
| Failed backup import preserves existing vault | Fixed (not integration-tested) | Tests show import validates and stages before it mutates. The interactive replacement flow is UI-limited. |
| Protected items close on system lock and sleep | Fixed (not integration-tested) | Session observers call `lockSensitiveItems()`. No automated macOS event test. |
| Sensitive field cannot be inserted without confirmation | Fixed (not integration-tested) | The code path requires presence when the item is configured and sensitive. Not UI-tested. |
| Critical insertion requires fresh authentication | Fixed (not integration-tested) | `insertSelected` calls `requirePresence` for `.critical`. |
| Authentication cancellation prevents insertion | Fixed (not integration-tested) | Cancellation propagates through `try await`. |
| Locking during authentication prevents insertion | Fixed (not integration-tested) | The operation ID and the session generation are checked after the await. |
| Stale target cannot receive insertion | Fixed (not integration-tested) | The focused element is compared again. |
| Focus changes cancel insertion | Fixed (not integration-tested) | Validation compares the original element. |
| New palette transaction invalidates old transaction | Partially implemented | An operation ID is tracked. A second palette invocation replaces the active target. No test races two executors. |
| Sensitive search data is invalidated on lock | Verified | `AppStateTests.testSealingInvalidatesTheIndexWithoutThePaletteView` |
| No automatic clipboard fallback | Static inspection | No clipboard reads or writes in the insertion path. |
| Persistence failure retains the open editor draft | Fixed (not integration-tested) | A save error appears globally and in the editor. An unsaved draft is not recovered after the window closes. |
| Out-of-order autosave tasks cannot restore stale state | Fixed (not integration-tested) | The queue serializes writes and checks for no-ops when it runs. Core tests cover a rapid revert and the latest fallback, not SwiftUI task scheduling. |
| Deleting or reordering fields cannot crash indexed bindings | Fixed (not integration-tested) | `FieldEditorRow` resolves the field ID on every binding access. Native deletion still needs testing. |
| Clearing a required name does not block other field edits | Verified | `SessionTests.testEditorSavesValidFieldsWhenTitleIsCleared` compares the encrypted round trip. The Core fallback tests pass. |
| Stale editor cannot overwrite imported item content | Core logic verified. UI untested | `VaultEditingTests.testEditorDoesNotOverwriteAnImportedItem` and a mutation check. Live import from Settings remains untested. |
| A rejected edit does not publish or persist partial changes | Verified | `SessionTests.testThrowingEditDoesNotPublishOrWritePartialChanges` compares stored bytes and payload |
| Permission checks cannot fail after a completed file replacement | Verified for application-level permission operations | `StorageTests.testPermissionCheckCannotFailAfterCommit` and a mutation check. Permissions are applied before the commit. |
| Preparation failure leaves the old vault intact | Verified | `StorageTests.testPrecommitPermissionFailurePreservesOriginalAndRemovesTemporaryFile` |
| Replacement keeps private file permissions | Verified | `StorageTests.testReplacementUsesPrivateNewPermissions` checks actual 0600 mode after replacing a 0644 test file |
| Imported tags and aliases survive editor text conversion | Domain logic verified. UI untested | `CommaSeparatedValuesTests` covers quoted roundtrip, including commas, quotes, whitespace, and empty strings |
| Import invalidates pending deletion confirmations | Session and domain logic verified. UI untested | Replacement advances the generation only after it succeeds. Confirmations capture the generation and the snapshot. The checked-deletion tests reject changed objects. |
| Failed name saves retain input and failed item deletion retains selection | Fixed (not integration-tested) | The name sheet awaits persistence and keeps local input when the save fails. Deletion changes the selection only in the success callback. |
| Type conversion cannot silently discard incompatible values | Core logic verified. UI untested | `VaultEditingTests.testIncompatibleTypeChangeRejectsInsteadOfDiscardingValue` |
| Secret editor saves retain at least sensitive classification | Core logic verified. UI untested | `VaultEditingTests.testSavingCannotDowngradeASecretToNormal` |
| Large numeric input cannot trap | Verified | `ModelsTests.testLargeNumberInsertionText` |
| Invalid random-number generation fails closed | Fixed (not integration-tested) | `SecRandomCopyBytes` status is checked. No path allocates all zeros. |
| Failed vault creation or protected-item unlock reports a reason to the user | Verified | `SessionTests.testFailedCreateRecordsLastError`, `testFailedProtectedUnlockRecordsLastError`, `testErrorFromSecondCreateIsRecorded` |
| Locking releases the decrypted payload and invalidates in-flight work | Verified | `SessionTests.testLockClearsPayloadAndAdvancesGeneration` |
| The vault opens at launch without user presence | Verified | `SensitiveItemTests.testOpeningAtLaunchNeverAsksForPresence` |
| A protected item's plaintext is absent from the vault file and from memory while locked | Verified | `SensitiveItemTests.testProtectedItemIsSealedAtRestAndInMemoryWhenLocked` |
| Marking an item protected without the sensitive key is refused | Verified | `SensitiveItemTests.testProtectingAnItemRequiresTheSensitiveKey` |
| Settings cannot mutate a locked vault | Fixed (not integration-tested) | `SettingsView` disables vault-backed settings when locked and `VaultSession.mutate` still rejects a locked session |
| A global shortcut that is unavailable does not disable the app | Fixed (not integration-tested) | `AppState.applyStoredShortcut` restores the default and reports the failure. `AppState.updateShortcut` restores the previous chord and reports when that also fails. No automated test covers Carbon registration failure. |
| A stored shortcut cannot register a global Escape intercept | Verified | `ShortcutTests.testEscapeIsNotRecordableAsAShortcut` |
| An encrypted backup carries protected items sealed | Verified | `SensitiveItemTests.testExportFromUnlockedSessionKeepsProtectedItemsSealed`, `testBackupCarriesProtectedItemsSealed` |
| Recovery seals protected items imported from an older backup | Verified | `SensitiveItemTests.testRecoverySealsProtectedItemsFromAnOlderBackup` |
| A seal during a write keeps the stored bytes and the in-memory copy in step | Verified | `SessionConcurrencyTests.testSealDuringWriteKeepsDiskAndMemoryInStep` |
| Undo waits for an in-flight save instead of conflicting with it | Verified | `SessionConcurrencyTests.testUndoDuringWriteWaitsInsteadOfConflicting` |

## Manual checks outstanding

These need a person at the keyboard:

- Global shortcut from arbitrary frontmost apps with the app's menu closed.
- Keyboard focus in the palette.
- Enter inserting into the correct control.
- Escape cancellation.
- Application switching cancellation.
- Lock hides the decrypted interface and invalidates it.
- Vault data surviving app restart.
- Stable Accessibility identity across rebuilds.
