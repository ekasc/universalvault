# UniversalVault completion

Active objective: finish the existing local macOS vault as a tested, usable application. No cloud service, browser extension, or unrelated product expansion.

## Completion gates

- [x] Read operating principles and prior acceptance reports.
- [x] Security: cancellation-safe unlock and creation, stale insertion rejection, strict import validation, concurrent-write conflict protection.
- [x] Features: safe backup recovery, reversible structural edits, item and field ordering, collapsible categories.
- [x] UI implementation: empty, locked, busy, error, and recovery states; keyboard controls; named native controls.
- [x] Local verification: 143 tests, debug and release builds, cross-process persistence, packaged native controls, real backup export, and both insertion strategies.
- [ ] Human and full-workflow acceptance: real authentication, VoiceOver, menu title refresh, shortcut delivery, reordering and rename/delete interactions, and third-party compatibility.
- [ ] Distribution: Developer ID signing, notarization, and signed-update Keychain continuity.
- [x] Documentation: current behavior, reproducible checks, and explicit remaining limitations.

## Design decisions

1. Keep SwiftUI, AppKit, Core, VaultSecurity, and Insertion. Do not replace the framework or redesign the product.
2. Compare-and-swap encrypted storage under a file lock rather than merely preventing a second app launch. This also detects external replacement and independent session objects.
3. Validate the complete payload at trust boundaries. Reject unsupported schemas and ambiguous identities; normalize legacy secret sensitivity and field values without discarding data.
4. Authorize insertion against the current field and session, and reject changes before and during dispatch.
5. Keep undo data only in the unlocked session and clear it on lock or replacement.
6. Native verification uses an explicit debug-only isolated launch mode, synthetic keys and data, and a bounded process lifetime. Production defaults never silently use test authentication.

## Sequence

1. Capture baseline and add failing security tests.
2. Repair session/storage and payload validation; verify each boundary.
3. Repair insertion transactions with testable authorization logic.
4. Complete core editing features and native UI, then exercise workflows.
5. Rebuild the bundle, check signing structure, and update acceptance evidence.

## External requirements

Production Developer ID signing and notarization require the owner's Apple credentials. Real Touch ID approval, TCC permission changes, and final VoiceOver acceptance cannot be replaced by synthetic authentication or source inspection.

## Current phase

The local implementation and automated verification pass is complete. The goal remains active. The next gates are full-workflow acceptance and distribution, as listed in `COMPLETION_REPORT.md`.
