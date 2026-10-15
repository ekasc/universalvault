# Compatibility

Insertion strategies: Accessibility `kAXSelectedTextAttribute` and controlled synthetic keyboard fallback. The clipboard is never used.

Automated tests in this repository cover domain models, validation, cryptography, backup, and vault lifecycle only. Accessibility and external-application insertion require interactive macOS permission state and are not automated in CI.

Untested by automation: TextEdit, Notes, Safari, Chrome/Chromium, Safari/Chrome rich text inputs, password or secure fields. Browser content origin cannot be verified by an external app; only application identity is presented and user authorization is required. The default app activation/focus wait is bounded; slow activation can cancel insertion even when the app eventually activates.

Manual compatibility matrix for this build:

| Application | Input type | Strategy | Verified outcome | Known limitations | Environment |
|---|---|---|---|---|---|
| TextEdit | Plain text field | Not executed | Not executed | Accessibility permission and interactive target required | macOS, manual |
| Safari | HTML text input | Not executed | Not executed | Cannot prove origin; app identity only | macOS, manual |
| Chrome | HTML text input | Not executed | Not executed | Cannot prove origin; app identity only | macOS, manual |
| Workday | Native/web inputs | Not executed | Not executed | No empirical claim is made | macOS, manual |

Manual tests must not submit external website forms or require real credentials.
