# Security

Threat model: unattended unlocked Mac, stolen vault file, clipboard sniffing, log exposure, wrong-target insertion, corrupted vault, tampered backup metadata.

Controls:

- AES-GCM authenticated encryption with a fresh random nonce per write.
- Required authenticated format metadata, including format version.
- 256-bit data-encryption key stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and user-presence access control.
- Non-destructive key creation; new key generation is rejected if an existing vault or key is detected.
- Random generation failures fail closed.
- Owner-restricted directory (`0700`) and vault-file (`0600`) permissions.
- Atomic replacement through temporary file and rename; errors surface.
- Session generation invalidation for lock/unlock/cancellation, plus inactivity, sleep, screen-lock, and termination handling.
- Sensitive and critical values are masked in UI previews and search results.
- Critical insertion always requires fresh user presence; sensitive insertion honors a configurable requirement.
- No clipboard use for insertion.
- Encrypted backup with PBKDF2-HMAC-SHA256, 200,000 iterations, a random salt, and authenticated metadata. Minimum backup passphrase length: 12 characters.
- Import validates and stages before replacing existing vault state.

Limits:

- Cannot protect against malware with equivalent or greater privileges or a compromised operating system.
- Cannot prove browser content origin from only an application bundle identifier; only application identity is presented.
- Memory zeroization is best-effort under Swift ARC.
- Clipboard scanning by other processes is outside this app's control, though UniversalVault does not use it.
- Real-world insertion tests are manually documented in `COMPATIBILITY.md`.

Status: repaired implementation with automated domain/crypto tests only. This is not an independent security audit or certification.
