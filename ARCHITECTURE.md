# Architecture

## Modules

- Core: domain models (`VaultItem`, `VaultField`, `VaultPayload`, search, templates, validation). No Apple security deps.
- VaultSecurity: storage, keychain, authentication, encryption, session management.
- Insertion: accessibility permission, focus capture, insertion engine (AX + keyboard fallback).
- App: SwiftUI menu bar app, vault window, quick-fill palette, shortcut registration.

## Data flow

VaultPayload (Codable) -> JSON -> AES-GCM (CryptoKit) -> file under Application Support/UniversalVault/vault.uv. Key (256-bit) stored in Keychain with user-presence access control. Decrypted payload held in `VaultSession` only while unlocked. Search index built in memory after unlock and discarded on lock.

## Insertion strategies

A. Accessibility: set `kAXSelectedTextAttribute` (inserts at caret / replaces selection). B. Synthetic keyboard events via CGEvent posted to target PID. C. Explicit failure (no clipboard fallback).

## Auto-lock

Inactivity timer checks every 30 seconds; locks after configured minutes (clamped 1–1440). `VaultSession` also locks on system sleep, screen-lock notification where available, and application termination. Each lock increments a session generation, invalidating stale insertion transactions and clearing sensitive UI state. Zeroization is best-effort under Swift ARC.
