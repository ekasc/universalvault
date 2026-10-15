# Implementation Report

Branch: `repair/security-reliability`

## Fixed and verified

- Vault creation cannot overwrite an existing vault or key; creation rejects existing vault/key and reports distinguishable states.
- Random-number generation failure fails closed.
- Tampered ciphertext and unsupported metadata versions fail decryption.
- Backup versioned envelope preserves metadata integrity and supports legacy import.
- Large numeric values cannot trap during `insertionText`.
- Field loading on macOS builds cleanly (Swift 6.2).
- `.app` bundle package can be assembled and ad-hoc signed.
- Models, validation, cryptography, backup, and vault lifecycle automated tests pass.

## Fixed but not integration-tested

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
