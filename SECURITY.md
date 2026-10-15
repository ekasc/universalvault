# Security

Threat model: unattended unlocked Mac, vault file theft, clipboard sniffing by other apps, logs exposure, wrong-target insertion, corrupted vault. Mitigations: AES-GCM authenticated encryption, Keychain-held DEK gated by user presence, session locking, no clipboard use, masking, fresh LAContext for critical operations.

Limits: cannot protect against malware with equivalent/greater privileges, compromised OS, or user sending secret to app. Memory zeroization not guaranteed under Swift ARC. Local storage may be included in backups/diagnostics; not automatic protection.

Encryption: AES-GCM, random 256-bit DEK, fresh nonce per write, AAD binds format. Key in Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + SecAccessControl userPresence. Backup uses PBKDF2-HMAC-SHA256 (200k iterations) via CommonCrypto, independent salt and nonce. Import authenticates before replacing data. No silent reset on failure.
