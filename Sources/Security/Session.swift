import Core
import Foundation
import AppKit
import CryptoKit
import Combine

@MainActor
public final class VaultSession: ObservableObject {
    @Published public private(set) var isUnlocked: Bool = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var sessionGeneration: UUID = UUID()

    private let storage: VaultStorage
    private let keyStore: VaultKeyStore
    private let auth: UserPresenceAuthenticating

    private var key: SymmetricKey?
    private var payload: VaultPayload?
    private var lastActivity: Date = Date()
    private var lockTimer: Timer?
    private var sleepObserver: (any NSObjectProtocol)?
    private var screenLockObserver: (any NSObjectProtocol)?
    private var terminateObserver: (any NSObjectProtocol)?

    public var onLock: (() -> Void)?

    public init(storage: VaultStorage, keyStore: VaultKeyStore, auth: UserPresenceAuthenticating) {
        self.storage = storage
        self.keyStore = keyStore
        self.auth = auth
        let nc = NotificationCenter.default
        terminateObserver = nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }


    public var currentPayload: VaultPayload? { payload }
    public var storageURL: URL { storage.url }

    public func existsVault() -> Bool { storage.exists() }

    public enum CreationStateError: Error, LocalizedError {
        case existingVault
        case missingKeyForExistingVault
        case vaultExistsAndKeyExists
        case unavailable
        public var errorDescription: String? {
            switch self {
            case .existingVault: return "A vault already exists."
            case .missingKeyForExistingVault: return "Vault exists but its key is missing; recovery required."
            case .vaultExistsAndKeyExists: return "Vault already exists."
            case .unavailable: return "Vault state cannot be determined."
            }
        }
    }

    public func createNewVault() async throws {
        _ = try await auth.authenticate(reason: "Create a new Universal Vault")

        let vaultExists = storage.exists()
        let keyExists: Bool
        do { keyExists = try keyStore.keyExists() } catch { throw CreationStateError.unavailable }

        if vaultExists && !keyExists {
            throw CreationStateError.missingKeyForExistingVault
        }
        if vaultExists && keyExists {
            throw CreationStateError.vaultExistsAndKeyExists
        }
        // Vault missing but abandoned key present: remove orphan key from interrupted init.
        if !vaultExists && keyExists {
            try keyStore.deleteKey()
        }

        let newKey = SymmetricKey(size: .bits256)
        try keyStore.storeKey(newKey)
        do {
            let p = VaultPayload()
            let data = try VaultCrypto.encrypt(payload: p, key: newKey)
            try storage.write(data)
            self.key = newKey
            self.payload = p
            self.isUnlocked = true
            self.sessionGeneration = UUID()
            self.touch()
            self.startAutoLock()
        } catch {
            // Never leave a newly created key without a committed vault.
            try? keyStore.deleteKey()
            throw error
        }
    }

    public func unlock() async throws {
        _ = try await auth.authenticate(reason: "Unlock Universal Vault")
        let k: SymmetricKey
        do {
            k = try keyStore.loadKey(reason: "Unlock vault")
        } catch KeyStoreError.notFound {
            throw CreationStateError.missingKeyForExistingVault
        }
        guard let data = try storage.read() else {
            throw CryptoEnvelopeError.invalidData
        }
        let p = try VaultCrypto.decrypt(data, key: k)
        self.key = k
        self.payload = p
        self.isUnlocked = true
        self.lastError = nil
        self.sessionGeneration = UUID()
        self.touch()
        self.startAutoLock()
    }

    public func lock() {
        self.sessionGeneration = UUID()
        self.key = nil
        self.payload = nil
        self.isUnlocked = false
        self.stopAutoLock()
        self.stopSystemObservers()
        self.onLock?()
    }

    public func touch() { lastActivity = Date() }

    private func startAutoLock() {
        stopAutoLock()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isUnlocked else { return }
                let minutes = self.payload?.settings.autoLockMinutes ?? 5
                let safeMinutes = max(1, min(minutes, 1440))
                if Date().timeIntervalSince(self.lastActivity) > Double(safeMinutes * 60) {
                    self.lock()
                }
            }
        }
        registerSystemObservers()
    }
    private func stopAutoLock() { lockTimer?.invalidate(); lockTimer = nil }
    private func registerSystemObservers() {
        stopSystemObservers()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
        // Screen lock is delivered via distributed notifications (not guaranteed across OS versions).
        screenLockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }
    private func stopSystemObservers() {
        if let t = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(t); sleepObserver = nil }
        if let t = screenLockObserver { DistributedNotificationCenter.default().removeObserver(t); screenLockObserver = nil }
    }

    // Data operations
    public func mutate(_ update: (inout VaultPayload) -> Void) async throws {
        guard isUnlocked, let k = key, var p = payload else { throw AuthError.failed("Vault locked") }
        update(&p)
        p.updatedAt = Date()
        for item in p.items {
            if !Validation.validateItem(item).isEmpty {
                throw VaultSessionError.invalidData("Item validation failed.")
            }
            for field in item.fields where !Validation.validateField(field).isEmpty {
                throw VaultSessionError.invalidData("Field validation failed.")
            }
        }
        let data = try VaultCrypto.encrypt(payload: p, key: k)
        try storage.write(data)
        self.payload = p
        self.touch()
    }

    public func requirePresence(reason: String) async throws {
        _ = try await auth.authenticate(reason: reason)
    }

    public struct VaultBackupEnvelope: Codable {
        public let format: String
        public let version: Int
        public let kdf: String
        public let iterations: Int
        public let salt: String
        public let sealedBox: String
    }

    private static let backupAAD = Data("UniversalVault|backup|v1".utf8)
    private static let minimumBackupPassphraseLength = 12

    public func savePayloadToBackup(passphrase: String) throws -> Data {
        guard passphrase.count >= Self.minimumBackupPassphraseLength else {
            throw VaultSessionError.invalidData("Backup passphrase must be at least \\(Self.minimumBackupPassphraseLength) characters.")
        }
        guard let p = payload else { throw AuthError.failed("Vault locked") }
        let salt = try Self.randomData(16)
        let iterations = 200_000
        let keyData = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: UInt32(iterations))
        let k = SymmetricKey(data: keyData)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let plaintext = try enc.encode(p)
        let sealed = try AES.GCM.seal(plaintext, using: k, authenticating: Self.backupAAD)
        guard let combined = sealed.combined else { throw CryptoEnvelopeError.invalidData }
        let env = VaultBackupEnvelope(
            format: "universal-vault-backup",
            version: 1,
            kdf: "PBKDF2-HMAC-SHA256",
            iterations: iterations,
            salt: salt.base64EncodedString(),
            sealedBox: combined.base64EncodedString())
        let envEnc = JSONEncoder()
        envEnc.outputFormatting = [.sortedKeys]
        return try envEnc.encode(env)
    }

    public static func importBackup(_ data: Data, passphrase: String) throws -> VaultPayload {
        // Try versioned format first
        if let first = data.first, first == UInt8(ascii: "{") {
            let decoder = JSONDecoder()
            if let env = try? decoder.decode(VaultBackupEnvelope.self, from: data),
               env.format == "universal-vault-backup", env.version == 1,
               let salt = Data(base64Encoded: env.salt),
               let boxData = Data(base64Encoded: env.sealedBox) {
                let keyData = try deriveKey(passphrase: passphrase, salt: salt, iterations: UInt32(env.iterations))
                let k = SymmetricKey(data: keyData)
                let box = try AES.GCM.SealedBox(combined: boxData)
                let plaintext = try AES.GCM.open(box, using: k, authenticating: Self.backupAAD)
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                return try dec.decode(VaultPayload.self, from: plaintext)
            }
        }
        // Legacy unversioned format: 16-byte salt + combined sealed box
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

    private static func randomData(_ n: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        guard status == errSecSuccess else { throw KeyStoreError.unexpected(status) }
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

public enum VaultSessionError: Error, LocalizedError {
    case invalidData(String)
    public var errorDescription: String? {
        switch self { case .invalidData(let m): return m }
    }
}
