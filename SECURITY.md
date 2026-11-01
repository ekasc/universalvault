# Security

Threat model: unattended unlocked Mac, stolen vault file, clipboard sniffing, log exposure, wrong-target insertion, corrupted vault, tampered backup metadata.

Controls:

- AES-GCM authenticated encryption with a fresh random nonce per write.
- Required authenticated format metadata, including format version.
- 256-bit data-encryption key stored in the data-protection Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and no user-presence requirement, so the vault opens at launch. The `com.universalvault.app` Mac Team provisioning profile and its `keychain-access-groups` entitlement must be embedded; without them the Keychain rejects the item with `errSecMissingEntitlement` and the app refuses vault creation.
- Items the user marks protected have their fields sealed with AES-GCM under a second key stored with `.userPresence` access control. That key is held only while protected items are open, and is dropped on sleep, screen lock, the inactivity timeout, and manual lock. Locked item fields are absent from the payload in memory, from search, and from quick fill; the vault file holds only the sealed box.
- The authenticated local-authentication context is reused for the Keychain read, so one unlock asks for presence once rather than twice.
- Non-destructive key creation; new key generation is rejected if an existing vault or key is detected.
- Random generation failures fail closed.
- Owner-restricted directory (`0700`) and vault-file (`0600`) permissions.
- Atomic replacement through temporary file and rename; errors surface.
- Session generation invalidation for lock/unlock/cancellation, plus inactivity, sleep, screen-lock, and termination handling.
- Sensitive and critical values are masked in UI previews and search results.
- Critical insertion always requires fresh user presence; sensitive insertion honors a configurable requirement.
- `UniversalVault --about-me` reads the vault with the vault key and prints only items marked shareable, minus sensitive, critical, and secret-typed fields. It never loads the sensitive key and never prompts. The filter is a code path, not an encryption boundary: sensitive field values are plaintext inside the payload, so a patched build could print them; protected items stay sealed.
- Vault-opening no longer authenticates. The threat that loses protection is a process that can drive the signed app while the Mac is unlocked: the vault key is readable without presence, so only protected items stay behind Touch ID. The vault file and its key remain protected by file permissions and the Keychain access group.
- No clipboard use for insertion.
- New encrypted backups use PBKDF2-HMAC-SHA256 with 600,000 iterations, a random salt, and authenticated metadata. Older backups remain readable. Minimum backup passphrase length: 12 characters.
- Import validates and stages before replacing existing vault state.
- Complete payload validation rejects unsupported schemas, duplicate identities, dangling references, and incompatible values. Legacy secret fields are raised to at least sensitive.
- Lock, cancellation, and newer authentication requests invalidate pending unlock, creation, and recovery work.
- Encrypted-byte compare-and-swap under an advisory file lock rejects stale saves across independent processes.
- Insertion authorization binds the current field, sensitive-field policy, and session generation. Changes cancel pending dispatch.
- Undo history is limited to 30 in-memory snapshots and cleared on lock, unlock, and replacement.
- Recovery authenticates and preserves the original encrypted file before a compare-and-swap replacement. It never deletes an existing Keychain key.
- Backup import and export share a 64 MiB file limit. Background encryption and import are generation-bound before the UI commits results.

Limits:

- Cannot protect against malware with equivalent or greater privileges or a compromised operating system.
- Cannot prove browser content origin from only an application bundle identifier; only application identity is presented.
- Memory zeroization is best-effort under Swift ARC.
- Clipboard scanning by other processes is outside this app's control, though UniversalVault does not use it.
- Real-world insertion tests are manually documented in `COMPATIBILITY.md`.
- Keychain user-presence authorization depends on an embedded provisioning profile. Personal Team profiles expire after seven days; `scripts/provision.sh` renews one.

Status: automated domain, authentication-race, persistence, and app-state tests, plus isolated native control and insertion checks. Real Keychain authentication and system lock delivery remain unverified. This is not a security certification. Current evidence is in `COMPLETION_REPORT.md`.
