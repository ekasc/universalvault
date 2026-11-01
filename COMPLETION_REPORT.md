# UniversalVault completion status

This report separates implemented behavior from observed runtime results.

## Implemented

- Cancellation-safe vault creation, unlock, recovery, and protected-field authentication.
- Cross-process compare-and-swap persistence with private file permissions and actionable conflict errors.
- Complete payload validation, legacy secret normalization, explicit empty dates, and unsupported-schema rejection.
- Current-field insertion authorization and UTF-16-safe keyboard chunks.
- Session-bounded undo and redo, item ordering, field ordering, and collapsible categories.
- Encrypted backup recovery with a preserved original encrypted file.
- Background backup encryption and bounded import, confirmation counts, passphrase confirmation, and generation-bound commits.
- Busy authentication controls, visible errors, masked previews, target context, and more readable narrow field controls.
- Reproducible application icon generation and separate release and debug verification bundles.

## Verification commands

`bash scripts/verify.sh` runs tests, release compilation, two-process storage contention, packaging, signature validation, and release verification isolation.

`bash scripts/verify.sh --native` also launches bounded native checks with synthetic authentication and disposable storage. The runner controls the real views and native field editors. It never uses the personal vault or real Keychain. Existing Accessibility permission is reused without a prompt or TCC modification.

## Observed results

- The suite has 145 tests: 90 CoreTests, 50 SecurityTests, and 5 AppTests. The final `--native` run passes with all 145.
- Debug and release compilation passed.
- Two independent processes raced a real `FileSystemVaultStorage` compare-and-swap. Exactly one committed and one received a conflict. The final file mode was 0600.
- Native controls created a vault and item, edited a Unicode field, and persisted the edits through encrypted backup and lock/unlock.
- Native accessibility inspection found no retained private field value after lock and no critical plaintext preview with previews enabled.
- A native Settings toggle persisted its changed value through the actual session save path.
- A stale editor draft was refused after another write changed the item: the banner appeared, the stored value stayed intact, and reloading cleared the message.
- Toolbar search filtered the list to its no-match state and cleared again.
- First-run creation with authentication denied showed the reason and left no vault behind.
- First-run creation showed progress with the create button disabled, and Cancel left no vault and no unlocked session. The Welcome window also prints the shortcut that is actually registered rather than the default.
- Recovery ran through the real restore sheet and its confirmation dialog. It restored the selected backup, wrote one private `vault-recovery-*.uv` archive, and that archive decrypted to the three pre-recovery items.
- Lock and undo ran through the same `AppState` entry points their menu items call. A real menu dispatch worked in one earlier run, but macOS installs a menu action only after it validates an open menu, which this harness cannot open, so menu dispatch is not part of the repeatable gate.
- The system save panel runs in a separate service. The automated export path writes directly to its staged destination, and panel interaction is a manual check.
- Category creation ran through the sidebar footer menu, the name sheet, and persistence, and the new category was selected afterwards.
- Replacing an unlocked vault from Settings restored the staged backup, cleared undo and redo history, and changed the session generation.
- Accessibility selected-text insertion and keyboard fallback delivered exact Unicode content into a separate native fixture process, preserving unrelated text.
- Canceled and expired insertion requests were rejected. Lock during chunked keyboard dispatch stopped delivery and reported a partial result.
- Real window screenshots cover light and dark editors, locked and empty states, settings, masked palette results, and backup sheets.
- Release packaging passed Info.plist and signature checks. The bundle is signed with the Apple Development identity and embeds the Mac Team provisioning profile when one is installed; without a profile it falls back to ad-hoc signing. Release verification flags exit before accessing storage.
- The final process and temporary-directory sweep found no remaining verification processes or synthetic vault directories.

The complete native backup export check passed. It fills secure inputs, opens the real save panel, presses Save through a separate process using Accessibility, and verifies the decrypted backup and 0600 file mode.

The initial in-process modal driver exposed actor reentrancy failures and attempted an unsupported `NSSavePanel.ok` action. Native actions now run through the Cocoa event queue. A bounded external helper presses the remote save panel's actual Save control. Backup callbacks explicitly return to the main actor. Native verification initializes the file chooser inside the isolated evidence directory.

## Evidence

- `.build/verification/tests.log`
- `.build/verification/release.log`
- `.build/verification/storage-processes.log`
- `.build/verification/package.log`
- `.build/verification/release-isolation.log`
- `.build/native-verification/result.json`, when the complete native run succeeds
- `.build/native-verification/save-panel-driver.json`
- `.build/native-verification/*-window.png` and matching accessibility JSON

View-cache screenshots without the `-window` suffix are diagnostic only. They do not prove complete rendering of native controls or system materials.

## Recovery coverage

- Recovery onto a machine with no vault and no Keychain key creates the key, writes the restored vault, and survives a later unlock.
- Recovery is rejected while the vault is unlocked, so a live session cannot be replaced behind the user.

## CI

`.github/workflows/verify.yml` runs the headless verifier on a `macos-26` runner and refuses to run when the macOS SDK is older than 26. It is manual-only and has not been executed on GitHub; the workflow YAML was checked structurally because no YAML parser is installed here.

## Guards

`scripts/check-invariants.sh` fails the build if any source file uses a clipboard API or calls `print`, `debugPrint`, or `NSLog`. The verifier runs it first. Those two properties have been asserted in reviews and docs since the first pass and were only checked by eye.

## Cleanup

- Removed the unused `InsertionTarget` type and an unused string literal in the native harness.
- Fixed the `var`-never-mutated warning in `ModelsTests`.
- `FileSystemVaultStorage` now reports `applicationSupportUnavailable` instead of force unwrapping a missing Application Support directory.
- First-run creation in the Welcome window now shows progress, can be cancelled, and reports failures. It previously started a second authentication prompt on a double click and discarded the thrown error.

## Remaining acceptance

These checks require separate evidence:

- Real Touch ID or password authentication, Keychain access control, and cancellation of real system prompts. Vault creation and unlock with real Touch ID and data-protection Keychain user-presence access control passed interactively on 2026-10-25 using the signed build; cancellation of a real system prompt is still unverified.
- Real sleep and screen-lock notifications on the distribution build.
- VoiceOver announcements, Full Keyboard Access, and contrast acceptance under system accessibility preferences.
- Full scene menu dispatch, global shortcut behavior, and third-party application compatibility.
- The Welcome window's successful creation. Its busy, cancel, and denial paths have native coverage; the success path shares the vault window's creation code, which is covered.
- Native acceptance of item and field reordering, category rename and delete, profile creation, and every focused-scene command. Their domain and persistence rules pass automated tests; those UI interactions are not yet covered. Context menu traversal through Accessibility blocked the app in this environment, so rename and delete were dropped from the harness rather than left flaky.
- Command title and enablement refresh in a real open menu. The harness cannot open a menu bar menu, so it no longer dispatches menu items.
- The toolbar search field carries its accessible name only through its placeholder. An explicit label needs a replacement search control, which would give up the native search affordances.
- Developer ID signing, notarization, and continuity across signed updates. No Apple credentials are configured or modified.

The GitHub Actions workflow runs the headless verifier and uploads an ad-hoc app archive. The workflow was added locally and has not run on GitHub. Native checks remain opt-in because hosted runners do not provide reliable permission and signed-in desktop state.

Multi-selection, multiple browsing windows, cloud sync, browser extensions, and public sharing are outside this local utility's completion scope. Unsupported schema versions fail closed rather than attempting an untested migration.
