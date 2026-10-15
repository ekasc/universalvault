# Security Regression Matrix

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
| Unlocked state cannot persist after system lock event | Fixed (not integration-tested) | Session observers invoke `lock()`; no automated macOS event test |
| Sensitive field cannot be inserted without confirmation | Fixed (not integration-tested) | Code path requires presence when configured and sensitive; not UI-tested |
| Critical insertion requires fresh authentication | Fixed (not integration-tested) | `insertSelected` calls `requirePresence` for `.critical` |
| Authentication cancellation prevents insertion | Fixed (not integration-tested) | Cancellation propagates through `try await` |
| Locking during authentication prevents insertion | Fixed (not integration-tested) | Operation ID and session generation checks after await |
| Stale target cannot receive insertion | Fixed (not integration-tested) | Focused element equality re-check |
| Focus changes cancel insertion | Fixed (not integration-tested) | Validation compares original element |
| New palette transaction invalidates old transaction | Partially implemented | Operation ID is tracked; a second palette invocation replaces the active target but does not carry a separate operation executor race test |
| Sensitive search data is invalidated on lock | Fixed (not integration-tested) | `clearSensitiveState` calls `searchEngine` state clearing indirectly through session lock callback |
| No automatic clipboard fallback | Static inspection | No clipboard reads or writes in insertion path |
| Persistence failure does not discard edited data | Fixed (not integration-tested) | VaultWindow saves serialized; UI remains loaded and error is surfaced |
| Out-of-order autosave tasks cannot restore stale state | Fixed (not integration-tested) | Save tasks are serialized and latest item value wins within a single editor |
| Deleting/reordering fields cannot crash indexed bindings | Fixed (not integration-tested) | `FieldEditorRow` uses field IDs |
| Large numeric input cannot trap | Verified | `ModelsTests.testLargeNumberInsertionText` |
| Invalid random-number generation fails closed | Fixed (not integration-tested) | `SecRandomCopyBytes` status checked; no allocated all-zero path |

Additional manual tests remain blocked or unexecuted:

- Global shortcut from arbitrary frontmost apps with the app's menu closed.
- Keyboard focus in the palette.
- Enter inserting into the correct control.
- Escape cancellation.
- Application switching cancellation.
- Lock hiding/invalidating decrypted UI.
- Vault data surviving app restart.
- Stable Accessibility identity across rebuilds.
