# UniversalVault macOS Acceptance Report

Commit: `f24167f` (`repair/security-reliability`)
macOS: 27.2 (build 26B5101f)
Machine: Mac14,2 (MacBook Air M2)
Xcode toolchain: installed local toolchain, Swift 6.2

## Automated and build verification

| Test | Result | Expected | Observed | Evidence |
|---|---|---|---|---|
| Swift build | PASS | `swift build` succeeds | `Build complete! (5.18 sec)` | Terminal output |
| Unit tests | PASS | 15 automated tests pass | 11 SecurityTests + 4 CoreTests pass | Terminal output |
| Ad-hoc `.app` packaging | PASS | Debug bundle builds and is ad-hoc signed | `.build/UniversalVault.app` produced by `scripts/build-app.sh debug` | Terminal output |
| Cold application launch | PASS locally | App launches from bundle | `.build/UniversalVault.app/Contents/MacOS/UniversalVault` remains running and exposes its accessory menu | Terminal output, process listing |

The initial launch crash in `PalettePanelController.init` was fixed by replacing `NSHostingController` content-view attachment with `NSHostingView` before launching the app. This is an observed runtime fix, not only a static source check.

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
7. Run the local HTML fixture in Safari and Chrome if installed.
8. Exercise lock, sleep, unlock, restart, export and restore with an isolated vault directory, using synthetic values only.

Do not use real passport numbers, payment-card numbers, or personal identity data. Do not overwrite an existing vault or Keychain item.

## Remaining blockers outside automated coverage

- Interactive Accessibility permission approval is required.
- Touch ID approval for vault unlock is required.
- Long-text, browser, lock/recovery, and backup tests were not executed.
- Production signing, notarization, entitlement review, and persistent shortcut customization remain future work.
- There are no GitHub Actions runs or commit statuses for this branch. Verification remains local.
