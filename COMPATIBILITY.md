# Compatibility

Insertion strategies: Accessibility `kAXSelectedTextAttribute` when the field's value verifiably changes, and Unicode typing through the HID event stream after the target application is activated. Events posted directly to a process id are dropped by Chromium's renderer, and web views report success for `AXSelectedText` without changing anything, so both are handled explicitly. The clipboard is never used.

The headless tests cover domain models, validation, cryptography, backup, vault lifecycle, and app state. Accessibility and external-application insertion require interactive macOS permission state and are not automated in CI.

The opt-in native verifier now tests a separate native NSTextView process through both Accessibility selected-text insertion and controlled keyboard fallback. Exact Unicode text, unrelated prefix and suffix preservation, expired and canceled requests, and lock during keyboard dispatch pass. This does not establish compatibility with third-party applications. Evidence: `.build/native-verification/result.json`.

Untested by automation: TextEdit, Notes, Safari, Chrome/Chromium, Safari/Chrome rich text inputs, password or secure fields. Browser content origin cannot be verified by an external app; only application identity is presented and user authorization is required. The default app activation/focus wait is bounded; slow activation can cancel insertion even when the app eventually activates.

Manual compatibility matrix for this build:

| Application | Input type | Strategy | Verified outcome | Known limitations | Environment |
|---|---|---|---|---|---|
| Electron app with a web text area | HTML/contenteditable text area | HID Unicode typing after activation | Filled through the right-click menu, 2026-10-25 | Synthetic typing is blocked by Secure Input and by password fields; the app's own context menu is replaced while the vault is unlocked | macOS 27, manual |
| TextEdit | Plain text field | Not executed | Not executed | Accessibility permission and interactive target required | macOS, manual |
| Safari | HTML text input | Not executed | Not executed | Cannot prove origin; app identity only | macOS, manual |
| Chrome | HTML text input | Not executed | Not executed | Cannot prove origin; app identity only | macOS, manual |
| Workday | Native/web inputs | Not executed | Not executed | No empirical claim is made | macOS, manual |

Manual tests must not submit external website forms or require real credentials.
