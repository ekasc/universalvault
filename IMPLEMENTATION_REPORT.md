# Implementation Report

Branch: `repair/security-reliability`

## Completed in this repair pass

- SPM project (Core, VaultSecurity, Insertion, App) builds cleanly (`swift build`).
- Encrypted vault (AES-GCM), Keychain DEK with non-destructive key creation, user-presence auth, atomic storage.
- Crash-safe vault creation: rejects existing vault/key, cleans orphaned abandoned key, rolls back a newly stored key on write failure.
- Keychain status determination now distinguishes missing vs. undeterminable.
- `SecRandomCopyBytes` failures now fail closed.
- Vault directory permissions tightened to `0700`; vault file remains `0600`.
- Ext (not replaced) `FieldValue` number conversion avoids Int overflow.
- Date insertion defaults to `YYYY-MM-DD`; `VaultField.preferredInsertFormat` supported.
- Session locking: inactivity clamping, system sleep and termination handling, session generation invalidation, sensitive UI clearing.
- Global shortcut decision is no longer dependent only on SwiftUI window state; menu-bar coordinator remains (NSPanel evaluation pending).
- Insertion transaction validation re-checks session, process liveness, application identity, focused element, and capability before dispatch.
- Keyboard fallback activation is bounded (max 0.5s), not a fixed 100 ms assumption.
- Field editor uses stable field IDs instead of array indices.
- Deletion requires confirmation.
- Save failures are surfaced, not discarded.
- Secret field type raises sensitivity to at least `.sensitive`.
- Sensitivity changes on insert: sensitive requires presence when configured; critical always requires fresh presence.
- Versioned backup format with PBKDF2, AAD-bound metadata; legacy backup import retained.
- Tests: 8/8 pass (3 Core + 5 Security).

## Fixed and verified

- Vault creation cannot overwrite an existing vault/key.
- Missing Keychain key is not silently replaced.
- Random-number failure fails closed.
- Tampered ciphertext/metadata still fails decryption.
- Backup uses versioned metadata and legacy compatibility.
- Insertion no longer trusts process ID alone.
- Numeric overflow avoided.
- Stale indexed field bindings removed.
- Save errors are not swallowed.

## Fixed but not integration-tested

- System-sleep and screen-lock locking (platform-dependent).
- Insertion into external macOS applications.
- Real global shortcut activation from arbitrary frontmost apps.
- Backup import into an existing vault workflow in the UI (backend method exists).
- Nsuppression of stale UI after lock on real multi-window setups.

## Still blocked

- Automated Accessibility-insertion tests require macOS `AXIsProcessTrusted` and interactive permission grants.
- Real-browser insertion compatibility not executed.

## Explicitly deferred

- Full NSPanel palette window controller.
- Application bundle packaging beyond `.app` documentation.
- Argon2id backup KDF (PBKDF2 retained with documented params).
- Undo for item deletion.
- Settings UI (shortcut persistence, backup/export/import UI) is partial.
