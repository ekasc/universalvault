import Core
import Foundation
import CryptoKit
import Combine

@MainActor
public final class VaultSession: ObservableObject {
    @Published public private(set) var isUnlocked: Bool = false
    @Published public private(set) var lastError: String?

    private let storage: VaultStorage
    private let keyStore: VaultKeyStore
    private let auth: UserPresenceAuthenticating

    private var key: SymmetricKey?
    private var payload: VaultPayload?
    private var lastActivity: Date = Date()
    private var lockTimer: Timer?

    public init(storage: VaultStorage, keyStore: VaultKeyStore, auth: UserPresenceAuthenticating) {
        self.storage = storage
        self.keyStore = keyStore
        self.auth = auth
    }

    public var currentPayload: VaultPayload? { payload }
    public var storageURL: URL { storage.url }

    public func existsVault() -> Bool { storage.exists() }

    public func createNewVault() async throws {
        // Authenticate to create
        _ = try await auth.authenticate(reason: "Create a new Universal Vault")
        let newKey = SymmetricKey(size: .bits256)
        try keyStore.storeKey(newKey)
        let p = VaultPayload()
        let data = try VaultCrypto.encrypt(payload: p, key: newKey)
        try storage.write(data)
        self.key = newKey
        self.payload = p
        self.isUnlocked = true
        self.touch()
        self.startAutoLock()
    }

    public func unlock() async throws {
        _ = try await auth.authenticate(reason: "Unlock Universal Vault")
        let k = try keyStore.loadKey(reason: "Unlock vault")
        guard let data = try storage.read() else {
            throw CryptoEnvelopeError.invalidData
        }
        let p = try VaultCrypto.decrypt(data, key: k)
        self.key = k
        self.payload = p
        self.isUnlocked = true
        self.lastError = nil
        self.touch()
        self.startAutoLock()
    }

    public func lock() {
        self.key = nil
        self.payload = nil
        self.isUnlocked = false
        self.stopAutoLock()
    }

    public func touch() { lastActivity = Date() }

    private func startAutoLock() {
        stopAutoLock()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isUnlocked else { return }
                let minutes = self.payload?.settings.autoLockMinutes ?? 5
                if Date().timeIntervalSince(self.lastActivity) > Double(minutes * 60) {
                    self.lock()
                }
            }
        }
    }
    private func stopAutoLock() { lockTimer?.invalidate(); lockTimer = nil }

    // Data operations
    public func mutate(_ update: (inout VaultPayload) -> Void) async throws {
        guard isUnlocked, let k = key, var p = payload else { throw AuthError.failed("Vault locked") }
        update(&p)
        p.updatedAt = Date()
        let data = try VaultCrypto.encrypt(payload: p, key: k)
        try storage.write(data)
        self.payload = p
        self.touch()
    }

    public func requirePresence(reason: String) async throws {
        _ = try await auth.authenticate(reason: reason)
    }

    public func savePayloadToBackup(passphrase: String) throws -> Data {
        // Passphrase-derived key via PBKDF2 (CommonCrypto)
        guard let p = payload else { throw AuthError.failed("Vault locked") }
        let salt = Self.randomData(16)
        let keyData = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: 200_000)
        let k = SymmetricKey(data: keyData)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let plaintext = try enc.encode(p) // payload only; encrypt
        // Use same AES-GCM with salt prepended
        let sealed = try AES.GCM.seal(plaintext, using: k)
        guard let combined = sealed.combined else { throw CryptoEnvelopeError.invalidData }
        var out = Data()
        out.append(salt)
        out.append(combined)
        return out
    }

    public static func importBackup(_ data: Data, passphrase: String) throws -> VaultPayload {
        guard data.count > 16 else { throw CryptoEnvelopeError.invalidData }
        let salt = data.prefix(16)
        let boxData = data.dropFirst(16)
        let keyData = try deriveKey(passphrase: passphrase, salt: Data(salt), iterations: 200_000)
        let k = SymmetricKey(data: keyData)
        let box = try AES.GCM.SealedBox(combined: Data(boxData))
        let plaintext = try AES.GCM.open(box, using: k)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(VaultPayload.self, from: plaintext)
    }

    private static func randomData(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> Data {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
            [UInt8](salt), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterations, &derived, derived.count)
        guard status == kCCSuccess else { throw CryptoEnvelopeError.decryptionFailed }
        return Data(derived)
    }
}

// CommonCrypto import
import CommonCrypto
