# Security Regression Matrix

Current completion evidence is in `COMPLETION_REPORT.md`. The historical matrix below predates the security and native verification pass.

| Additional requirement | Status | Evidence |
|---|---|---|
| Lock invalidates pending protected-item unlock and creation | Verified with controlled authentication | `SessionConcurrencyTests` |
| Changed field cannot reuse pending insertion authorization | Verified | `InsertionAuthorizationTests`, `AppStateTests.testFieldChangedDuringActualAuthenticationCancelsInsertion` |
| Imported secrets cannot retain normal sensitivity | Verified | `PayloadValidationTests`, `PayloadBoundaryTests` |
| Competing processes cannot silently overwrite saves | Verified | `scripts/verify-storage-processes.py` |
| Undo persists and clears on lock or replacement | Verified | `HistoryRecoveryTests` |
| Recovery preserves original encrypted bytes | Verified with synthetic keys | `HistoryRecoveryTests.testRecoveryPreservesOriginalAndRestoresIndependentBackup` |
| Native backup export writes a decryptable private file | Verified with synthetic authentication | `.build/native-verification/result.json` |
| Native recovery preserves the original encrypted file and restores the backup | Verified with synthetic authentication | `.build/native-verification/result.json`, `13-recovered-window.png` |
| Lock command dispatches through the application menu | Observed once; not in the repeatable gate | Menu actions require an open, validated menu |
| Replace-while-unlocked clears undo and redo history | Verified with synthetic authentication | `.build/native-verification/result.json` |
| Category creation persists through the real sidebar menu and sheet | Verified | `.build/native-verification/14-category-created-window.png` |
| A stale editor draft cannot overwrite an item changed elsewhere | Verified in a real editor | `staleEditorConflict` in `.build/native-verification/result.json` |
| Toolbar search filters the item list and reports no matches | Verified | `.build/native-verification/16-search-no-match-window.png` |
| Keyboard insertion preserves Unicode and stops after lock | Verified against native fixture | `.build/native-verification/result.json`, `UnicodeEventChunksTests` |
| Release builds reject synthetic verification before storage access | Verified | `.build/verification/release-isolation.log` |

Status legend: `Verified` = automated test or documented build evidence. `Fixed (not integration-tested)` = code changed but manual/integration evidence not available. `Blocked` = cannot execute in available environment.

| Requirement | Status | Evidence |
|---|---:|---|
| Cannot overwrite existing vault during creation | Verified | `CryptoTests.testCreateVaultTwiceThrows` |
| Existing key survives failed vault initialization | Fixed (not integration-tested) | Creation rolls back a new key on write failure; not simulated exhaustively |
| Keychain failure does not trigger new key generation | Fixed (not integration-tested) | `keyExists` errors surface; no automatic generation path |
| Failed migration preserves old data | Fixed (not integration-tested) | No migration command exposed for destructive rotation |
| Tampered ciphertext cannot decrypt | Verified | `CryptoTests.testTamper` |
| Tampered security metadata cannot be accepted | Verified | `CryptoTests.testUnsupportedVersion` |
| Failed backup import preserves existing vault | Fixed (not integration-tested) | Import validates/stages before mutation in tests, but interactive replacement flow remains UI-limited |
| Protected items close on system lock and sleep | Fixed (not integration-tested) | Session observers invoke `lockSensitiveItems()`; no automated macOS event test |
| Sensitive field cannot be inserted without confirmation | Fixed (not integration-tested) | Code path requires presence when configured and sensitive; not UI-tested |
| Critical insertion requires fresh authentication | Fixed (not integration-tested) | `insertSelected` calls `requirePresence` for `.critical` |
| Authentication cancellation prevents insertion | Fixed (not integration-tested) | Cancellation propagates through `try await` |
| Locking during authentication prevents insertion | Fixed (not integration-tested) | Operation ID and session generation checks after await |
| Stale target cannot receive insertion | Fixed (not integration-tested) | Focused element equality re-check |
| Focus changes cancel insertion | Fixed (not integration-tested) | Validation compares original element |
| New palette transaction invalidates old transaction | Partially implemented | Operation ID is tracked; a second palette invocation replaces the active target but does not carry a separate operation executor race test |
| Sensitive search data is invalidated on lock | Verified | `AppStateTests.testSealingInvalidatesTheIndexWithoutThePaletteView` |
| No automatic clipboard fallback | Static inspection | No clipboard reads or writes in insertion path |
| Persistence failure retains the open editor draft | Fixed (not integration-tested) | Save error appears globally and in the editor; unsaved drafts are not recovered after window close |
| Out-of-order autosave tasks cannot restore stale state | Fixed (not integration-tested) | Queue serializes writes and checks no-ops at execution; Core tests cover rapid revert and latest fallback, not SwiftUI task scheduling |
| Deleting/reordering fields cannot crash indexed bindings | Fixed (not integration-tested) | `FieldEditorRow` resolves the field ID on every binding access; native deletion still needs testing |
| Clearing a required name does not block other field edits | Verified | `SessionTests.testEditorSavesValidFieldsWhenTitleIsCleared` checks encrypted roundtrip; Core fallback tests also pass |
| Stale editor cannot overwrite imported item content | Core logic verified; UI untested | `VaultEditingTests.testEditorDoesNotOverwriteAnImportedItem` plus mutation check; live Settings import remains untested |
| A rejected edit does not publish or persist partial changes | Verified | `SessionTests.testThrowingEditDoesNotPublishOrWritePartialChanges` compares stored bytes and payload |
| Permission checks cannot fail after a completed file replacement | Verified for application-level permission operations | `StorageTests.testPermissionCheckCannotFailAfterCommit` plus mutation check; permissions are applied before commit |
| Preparation failure leaves the old vault intact | Verified | `StorageTests.testPrecommitPermissionFailurePreservesOriginalAndRemovesTemporaryFile` |
| Replacement keeps private file permissions | Verified | `StorageTests.testReplacementUsesPrivateNewPermissions` checks actual 0600 mode after replacing a 0644 test file |
| Imported tags and aliases survive editor text conversion | Domain logic verified; UI untested | `CommaSeparatedValuesTests` covers quoted roundtrip, including commas, quotes, whitespace, and empty strings |
| Import invalidates pending deletion confirmations | Session/domain logic verified; UI untested | Replacement advances generation only after success; confirmations capture generation and snapshot; checked-deletion tests reject changed objects |
| Failed name saves retain input and failed item deletion retains selection | Fixed (not integration-tested) | Name sheet awaits persistence and retains local input on failure; deletion changes selection only in success callback |
| Type conversion cannot silently discard incompatible values | Core logic verified; UI untested | `VaultEditingTests.testIncompatibleTypeChangeRejectsInsteadOfDiscardingValue` |
| Secret editor saves retain at least sensitive classification | Core logic verified; UI untested | `VaultEditingTests.testSavingCannotDowngradeASecretToNormal` |
| Large numeric input cannot trap | Verified | `ModelsTests.testLargeNumberInsertionText` |
| Invalid random-number generation fails closed | Fixed (not integration-tested) | `SecRandomCopyBytes` status checked; no allocated all-zero path |
| Failed vault creation or protected-item unlock reports a reason to the user | Verified | `SessionTests.testFailedCreateRecordsLastError`, `testFailedProtectedUnlockRecordsLastError`, `testErrorFromSecondCreateIsRecorded` |
| Locking releases the decrypted payload and invalidates in-flight work | Verified | `SessionTests.testLockClearsPayloadAndAdvancesGeneration` |
| The vault opens at launch without user presence | Verified | `SensitiveItemTests.testOpeningAtLaunchNeverAsksForPresence` |
| A protected item's plaintext is absent from the vault file and from memory while locked | Verified | `SensitiveItemTests.testProtectedItemIsSealedAtRestAndInMemoryWhenLocked` |
| Marking an item protected without the sensitive key is refused | Verified | `SensitiveItemTests.testProtectingAnItemRequiresTheSensitiveKey` |
| Settings cannot mutate a locked vault | Fixed (not integration-tested) | `SettingsView` disables vault-backed settings when locked and `VaultSession.mutate` still rejects a locked session |
| A global shortcut that is unavailable does not disable the app | Fixed (not integration-tested) | `AppState.applyStoredShortcut` restores the default and reports; `AppState.updateShortcut` restores the previous chord on failure and says so when even that fails. No automated test covers Carbon registration failure. |
| A stored shortcut cannot register a global Escape intercept | Verified | `ShortcutTests.testEscapeIsNotRecordableAsAShortcut` |

Additional manual tests remain blocked or unexecuted:

- Global shortcut from arbitrary frontmost apps with the app's menu closed.
- Keyboard focus in the palette.
- Enter inserting into the correct control.
- Escape cancellation.
- Application switching cancellation.
- Lock hiding/invalidating decrypted UI.
- Vault data surviving app restart.
- Stable Accessibility identity across rebuilds.
