# Architecture

## Modules

- Core: domain models (`VaultItem`, `VaultField`, `VaultPayload`, search, templates, validation). No Apple security deps.
- VaultSecurity: storage, keychain, authentication, encryption, session management.
- Insertion: accessibility permission, focus capture, insertion engine (AX + keyboard fallback).
- App: SwiftUI menu bar app, vault window, AppKit-owned quick-fill panel, shortcut registration.

## Quick fill flow

The palette is an `NSPanel` with `.nonactivatingPanel`, owned by `AppState`, not a SwiftUI `Window`. This matters for two reasons: the menu-bar view does not exist while the menu is closed (so it cannot own palette presentation), and a normal window would activate Universal Vault and steal focus from the field being filled.

1. Capture the focused AX element before any UI or authentication runs, including its on-screen rectangle and whether it is a password-style field.
2. If the captured app is Universal Vault itself, re-activate the last regular app and capture again.
3. If locked, unlock once through the Keychain item's `userPresence` access control. No separate `LAContext` call on this path.
4. Show the panel anchored to the captured field (below it, flipping above when there is no room; centered as a fallback), without activating the app.
5. On a password field with an empty query, rank secret and sensitive fields first so the first click is usually right.
6. Hide the panel, re-activate the target app, wait for focus, then insert.

Failure is reported inside the panel (including a missing Accessibility permission), and the panel reopens with the same query so the user can retry immediately.

## Data flow

VaultPayload (Codable) -> JSON -> AES-GCM (CryptoKit) -> file under Application Support/UniversalVault/vault.uv. Key (256-bit) stored in Keychain with user-presence access control. Decrypted payload held in `VaultSession` only while unlocked. Search index built in memory after unlock and discarded on lock.

## Insertion strategies

A. Accessibility: set `kAXSelectedTextAttribute` (inserts at caret / replaces selection). B. Synthetic keyboard events via CGEvent posted to target PID. C. Explicit failure (no clipboard fallback).

## Auto-lock

Inactivity timer checks every 30 seconds; locks after configured minutes. NSWorkspace sleep/session-lock handling can be added to VaultSession.
