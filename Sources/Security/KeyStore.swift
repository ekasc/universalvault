import Core
import Foundation
import Security
import CryptoKit

public protocol VaultKeyStore: Sendable {
    func keyExists() -> Bool
    func loadKey(reason: String) throws -> SymmetricKey
    func storeKey(_ key: SymmetricKey) throws
    func deleteKey() throws
}

public enum KeyStoreError: Error, LocalizedError {
    case notFound
    case accessDenied
    case unexpected(OSStatus)
    case accessControlCreationFailed

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Vault key not found."
        case .accessDenied: return "Access to vault key denied."
        case .unexpected(let s): return "Keychain error: \(s)"
        case .accessControlCreationFailed: return "Could not create key access control."
        }
    }
}

public final class KeychainVaultKeyStore: VaultKeyStore {
    private let service = "com.universalvault.vaultkey"
    private let account = "dek"

    public init() {}

    public func keyExists() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess
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

    public func storeKey(_ key: SymmetricKey) throws {
        // Remove any existing
        try? deleteKey()
        let ac = try accessControl()
        let data = key.withUnsafeBytes { Data($0) }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: ac,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.unexpected(status) }
    }

    public func loadKey(reason: String) throws -> SymmetricKey {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeyStoreError.notFound }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            throw KeyStoreError.notFound
        case errSecAuthFailed, errSecUserCanceled:
            throw KeyStoreError.accessDenied
        default:
            throw KeyStoreError.unexpected(status)
        }
    }

    public func deleteKey() throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeyStoreError.unexpected(status)
        }
    }
}
