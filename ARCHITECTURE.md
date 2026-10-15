# Architecture

## Modules

- Core: domain models, search, templates, validation. No Apple security dependencies.
- VaultSecurity: storage, Keychain access, user-presence authentication, encryption, session management.
- Insertion: Accessibility permission, focus capture, insertion engine using AX and controlled keyboard fallback.
- App: SwiftUI menu-bar app, vault window, quick-fill palette, global shortcut, settings, packaging inputs.

## Data flow

`VaultPayload` (Codable) -> JSON -> AES-GCM (CryptoKit) -> file under `Application Support/UniversalVault/vault.uv`. The 256-bit data-encryption key is stored in Keychain with user-presence access control. The decrypted payload is held by `VaultSession` only while unlocked. Secure memory cleanup is best-effort under Swift ARC.

Search runs over the in-memory decrypted payload and is cleared by the lock path. Search results contain field references but value previews are masked for sensitive and critical fields in the palette UI.

## Insertion flow

1. Capture the focused Accessibility element and its application before showing the palette.
2. Validate the same element, process, application identity, capabilities, and session before dispatch.
3. Use Accessibility insertion for supported writable controls.
4. Use controlled CGEvent fallback only after revalidation.
5. Return structured outcomes: verified, unverified/dispatched, canceled, rejected, failed, or partial.
6. Never use clipboard fallback or target another input.

## Locking

`VaultSession` locks on explicit logout, inactivity, system sleep, screen-lock notification, and application termination. Any lock changes the session generation, invalidating asynchronous insertion work and clearing palette/search/editor state.

## Packaging

`scripts/build-app.sh` builds an executable with Swift Package Manager and assembles an accessory app bundle with a stable bundle identifier, Info.plist, and ad-hoc signature. It is not a production distribution pipeline.

## Open limitations

- Real insertion compatibility is listed in `COMPATIBILITY.md`.
- Native window integration tests requiring Accessibility permission are not automated.
