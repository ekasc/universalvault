import Core
import Foundation
import Security
import CryptoKit

public protocol VaultKeyStore: Sendable {
    func keyExists() throws -> Bool
    func loadKey(reason: String) throws -> SymmetricKey
    /// `context` carries presence that was already authenticated for this
    /// action; reusing it avoids a second system prompt on the same read.
    func loadKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey
    func storeKey(_ key: SymmetricKey) throws
    func deleteKey() throws

    /// The sensitive key seals the contents of items the user marked. It is
    /// released only after user presence, so this call can prompt.
    func sensitiveKeyExists() throws -> Bool
    func loadSensitiveKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey
    func storeSensitiveKey(_ key: SymmetricKey) throws
    func deleteSensitiveKey() throws

    func needsOpenKeyMigration() throws -> Bool
    /// Rewrites the legacy presence-protected vault key so it can be read at
    /// launch. Returns true when a migration happened.
    func migrateOpenKey(context: AuthenticatedContext?) throws -> Bool
}

public extension VaultKeyStore {
    func loadKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey {
        try loadKey(reason: reason)
    }

    func needsOpenKeyMigration() throws -> Bool { false }

    func migrateOpenKey(context: AuthenticatedContext?) throws -> Bool { false }

    func sensitiveKeyExists() throws -> Bool { false }

    func loadSensitiveKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey {
        throw KeyStoreError.sensitiveKeyUnavailable
    }

    func storeSensitiveKey(_ key: SymmetricKey) throws {
        throw KeyStoreError.sensitiveKeyUnavailable
    }

    func deleteSensitiveKey() throws {}
}

public enum KeyStoreError: Error, LocalizedError {
    case notFound
    case accessDenied
    case unexpected(OSStatus)
    case accessControlCreationFailed
    case alreadyExists
    case statusUnknown(OSStatus)
    case signingRequired
    case presenceRequired
    case sensitiveKeyUnavailable
    case migrationFailed

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Vault key not found."
        case .accessDenied: return "Access to vault key denied."
        case .unexpected(let s): return "Keychain error: \(s)"
        case .accessControlCreationFailed: return "Could not create key access control."
        case .alreadyExists: return "A vault key already exists."
        case .statusUnknown(let s): return "Keychain status could not be determined: \(s)"
        case .signingRequired:
            return "This build is not signed for Keychain access. Rebuild with scripts/build-app.sh so the Mac Team provisioning profile is embedded."
        case .presenceRequired:
            return "This vault key needs Touch ID before it can be read."
        case .sensitiveKeyUnavailable:
            return "Protected items are not available in this build."
        case .migrationFailed:
            return "The vault key could not be migrated; the existing key was left untouched."
        }
    }
}

public final class KeychainVaultKeyStore: VaultKeyStore {
    private let service = "com.universalvault.vaultkey"
    /// The current vault key: readable at launch, which is what opens the vault
    /// without a prompt.
    private let openAccount = "dek.open"
    /// The item written by builds that required presence to open the vault.
    private let legacyAccount = "dek"
    private let sensitiveAccount = "sek"

    public init() {}

    /// Every query targets the data-protection Keychain. The open vault key no
    /// longer needs user presence, but the sensitive key still does, and the
    /// access-control entitlement is what makes that work.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func failure(_ status: OSStatus) -> KeyStoreError {
        status == errSecMissingEntitlement ? .signingRequired : .unexpected(status)
    }

    private func exists(account: String) throws -> Bool {
        var q = baseQuery(account: account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        case errSecMissingEntitlement: throw KeyStoreError.signingRequired
        default: throw KeyStoreError.statusUnknown(status)
        }
    }

    public func keyExists() throws -> Bool {
        try exists(account: openAccount) || exists(account: legacyAccount)
    }

    private func accessControl() throws -> SecAccessControl {
        var err: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence, &err) else {
            throw KeyStoreError.accessControlCreationFailed
        }
        return ac
    }

    // MARK: - Vault key

    public func storeKey(_ key: SymmetricKey) throws {
        if try exists(account: openAccount) { throw KeyStoreError.alreadyExists }
        var q = baseQuery(account: openAccount)
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeyStoreError.alreadyExists }
        guard status == errSecSuccess else { throw failure(status) }
    }

    public func loadKey(reason: String) throws -> SymmetricKey {
        try loadKey(reason: reason, context: nil)
    }

    public func loadKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey {
        if let key = try read(account: openAccount, context: nil, prompt: false) {
            return key
        }
        if let key = try read(account: legacyAccount, context: context, prompt: true) {
            return key
        }
        throw KeyStoreError.notFound
    }

    public func needsOpenKeyMigration() throws -> Bool {
        try exists(account: legacyAccount) && !exists(account: openAccount)
    }

    public func migrateOpenKey(context: AuthenticatedContext?) throws -> Bool {
        guard try needsOpenKeyMigration() else { return false }
        guard let key = try read(account: legacyAccount, context: context, prompt: true) else {
            throw KeyStoreError.notFound
        }
        var q = baseQuery(account: openAccount)
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw failure(status)
        }
        // The legacy item is the only copy until this read proves the new one is
        // usable. A failed verification leaves both items in place.
        guard let written = try read(account: openAccount, context: nil, prompt: false),
            written.withUnsafeBytes({ Data($0) }) == key.withUnsafeBytes({ Data($0) })
        else {
            throw KeyStoreError.migrationFailed
        }
        SecItemDelete(baseQuery(account: legacyAccount) as CFDictionary)
        return true
    }

    public func deleteKey() throws {
        for account in [openAccount, legacyAccount] {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw failure(status)
            }
        }
        try deleteSensitiveKey()
    }

    // MARK: - Sensitive key

    public func sensitiveKeyExists() throws -> Bool {
        try exists(account: sensitiveAccount)
    }

    public func loadSensitiveKey(reason: String, context: AuthenticatedContext?)
        throws -> SymmetricKey
    {
        if let key = try read(account: sensitiveAccount, context: context, prompt: true) {
            return key
        }
        throw KeyStoreError.notFound
    }

    public func storeSensitiveKey(_ key: SymmetricKey) throws {
        if try exists(account: sensitiveAccount) { throw KeyStoreError.alreadyExists }
        var q = baseQuery(account: sensitiveAccount)
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessControl as String] = try accessControl()
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeyStoreError.alreadyExists }
        guard status == errSecSuccess else { throw failure(status) }
    }

    public func deleteSensitiveKey() throws {
        let status = SecItemDelete(baseQuery(account: sensitiveAccount) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw failure(status)
        }
    }

    // MARK: - Reading

    /// `prompt == false` uses the fail-only authentication UI, so a presence
    /// requirement is reported instead of interrupting the user with a dialog.
    private func read(
        account: String, context: AuthenticatedContext?, prompt: Bool
    ) throws -> SymmetricKey? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            q[kSecUseAuthenticationContext as String] = context.context
        } else if !prompt {
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeyStoreError.notFound }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecUserCanceled:
            throw KeyStoreError.accessDenied
        case errSecInteractionNotAllowed:
            throw KeyStoreError.presenceRequired
        case errSecMissingEntitlement:
            throw KeyStoreError.signingRequired
        default:
            throw KeyStoreError.unexpected(status)
        }
    }
}
