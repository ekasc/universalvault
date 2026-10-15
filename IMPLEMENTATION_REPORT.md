# Implementation Report

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

- Fully persistent shortcut customization beyond the default global registration.
- Argon2id or another memory-hard backup KDF; retained PBKDF2 (200,000 iterations) with documented parameters.
- Undo for item deletion.
- Complete domain migration/recovery UI.
- Production signing, notarization, and entitlement review.

## Current verification

- `swift build` passes.
- `swift test` passes: 4 CoreTests and 7 SecurityTests.
- `./scripts/build-app.sh debug` assembles and ad-hoc signs `.build/UniversalVault.app`.

## Changed documentation

- `README.md`
- `ARCHITECTURE.md`
- `SECURITY.md`
- `COMPATIBILITY.md`
- `SECURITY_REGRESSION_MATRIX.md`
