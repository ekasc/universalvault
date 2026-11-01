import Core
import Foundation
import AppKit
import CryptoKit
import Combine

@MainActor
public final class VaultSession: ObservableObject {
    @Published public private(set) var isUnlocked: Bool = false
    /// True while the sensitive key is held. Items the user marked readable only
    /// in this state.
    @Published public private(set) var isSensitiveUnlocked: Bool = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var sessionGeneration: UUID = UUID()

    private let storage: VaultStorage
    private let keyStore: VaultKeyStore
    private let auth: UserPresenceAuthenticating

    private let mutationGate = AsyncGate()
    private let mutationWriter = VaultMutationWriter()
    private var key: SymmetricKey?
    private var sensitiveKey: SymmetricKey?
    private var ciphertext: Data?
    private var authenticationRequest = UUID()
    private struct HistoryEntry {
        let name: String
        let payload: VaultPayload
    }
    @Published private var undoEntries: [HistoryEntry] = []
    @Published private var redoEntries: [HistoryEntry] = []
    // Published so that views reading `currentPayload` re-render on an edit.
    // `isUnlocked`/`sessionGeneration` do not change when a payload is mutated.
    @Published private var payload: VaultPayload?
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
        registerSystemObservers()
    }

    isolated deinit {
        lockTimer?.invalidate()
        if let token = terminateObserver { NotificationCenter.default.removeObserver(token) }
        if let token = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let token = screenLockObserver { DistributedNotificationCenter.default().removeObserver(token) }
    }


    public var currentPayload: VaultPayload? { payload }
    public var storageURL: URL { storage.url }
    /// Items the user protected whose contents are not in memory.
    public var lockedItemCount: Int { payload?.items.filter(\.isLocked).count ?? 0 }
    public var sensitiveItemCount: Int { payload?.items.filter(\.isSensitive).count ?? 0 }
    public var canUndo: Bool { isUnlocked && !undoEntries.isEmpty }
    public var canRedo: Bool { isUnlocked && !redoEntries.isEmpty }
    public var undoActionName: String { undoEntries.last?.name ?? "Vault Change" }
    public var redoActionName: String { redoEntries.last?.name ?? "Vault Change" }

    public func existsVault() -> Bool { storage.exists() }

    public enum CreationStateError: Error, LocalizedError, Equatable {
        case existingVault
        case missingKeyForExistingVault
        case vaultExistsAndKeyExists
        case keyExistsWithoutVault
        case unavailable
        public var errorDescription: String? {
            switch self {
            case .existingVault: return "A vault already exists."
            case .missingKeyForExistingVault: return "Vault exists but its key is missing; recovery required."
            case .vaultExistsAndKeyExists: return "Vault already exists."
            case .keyExistsWithoutVault: return "A Keychain key exists without a corresponding vault; recovery is required."
            case .unavailable: return "Vault state cannot be determined."
            }
        }
    }

    /// Creates a vault and records the outcome in `lastError`.
    ///
    /// `lastError` is the single place UI reads "what went wrong", because the
    /// call sites are button actions that cannot usefully propagate a throw.
    public func createNewVault() async throws {
        let request = UUID()
        authenticationRequest = request
        do {
            try await performCreateNewVault(request: request)
            lastError = nil
        } catch {
            if authenticationRequest == request {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }
    }

    private func performCreateNewVault(request: UUID) async throws {
        try checkAuthenticationRequest(request)
        let vaultExisted = storage.exists()
        let keyExists: Bool
        do { keyExists = try keyStore.keyExists() } catch { throw CreationStateError.unavailable }

        if vaultExisted && !keyExists {
            throw CreationStateError.missingKeyForExistingVault
        }
        if vaultExisted && keyExists {
            throw CreationStateError.vaultExistsAndKeyExists
        }
        if !vaultExisted && keyExists {
            throw CreationStateError.keyExistsWithoutVault
        }

        let newKey = SymmetricKey(size: .bits256)
        let p = VaultPayload()
        let data = try VaultCrypto.encrypt(payload: p, key: newKey)
        try keyStore.storeKey(newKey)
        // A failed write cannot prove exclusive ownership of a shared Keychain key.
        // Leave it available for recovery rather than deleting another writer's key.
        try storage.write(data, expected: nil)

        self.key = newKey
        self.ciphertext = data
        self.payload = p
        self.isUnlocked = true
        self.sensitiveKey = nil
        self.isSensitiveUnlocked = false
        self.sessionGeneration = UUID()
        self.undoEntries = []
        self.redoEntries = []
        self.touch()
        self.startAutoLock()
    }

    /// Opens the vault and records the outcome in `lastError`.
    ///
    /// The vault key is not user-presence protected, which is what lets the app
    /// open without a prompt. Items the user marked sensitive stay sealed until
    /// `unlockSensitiveItems` supplies the second key.
    public func unlock() async throws {
        let request = UUID()
        authenticationRequest = request
        do {
            try await openVault(request: request)
            lastError = nil
        } catch {
            if authenticationRequest == request {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }
    }

    /// Opens an existing vault at launch. A vault created by an older build kept
    /// its key behind user presence; that one key is migrated once, with the
    /// prompt it always needed, and never again.
    public func openIfAvailable() async {
        guard !isUnlocked, storage.exists() else { return }
        let request = UUID()
        authenticationRequest = request
        do {
            try await openVault(request: request)
            lastError = nil
        } catch {
            if authenticationRequest == request {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The whole open path — Keychain reads, the file, and decryption — runs off
    /// the main actor, so it finishes while SwiftUI is still building the first
    /// window instead of queueing behind it.
    private func openVault(request: UUID) async throws {
        let storage = self.storage
        let keyStore = self.keyStore
        let auth = self.auth
        let generation = sessionGeneration
        let loaded = try await Task.detached(priority: .userInitiated) { () async throws -> (
            Data, VaultPayload, SymmetricKey
        ) in
            if try keyStore.needsOpenKeyMigration() {
                let approved = try await auth.authenticate(
                    reason: "Move the vault key so UniversalVault opens without a prompt from now on")
                guard approved else { throw AuthError.canceled }
                _ = try keyStore.migrateOpenKey(context: auth.authenticatedContext())
            }
            let key: SymmetricKey
            do {
                key = try keyStore.loadKey(reason: "Open vault", context: auth.authenticatedContext())
            } catch KeyStoreError.notFound {
                throw AuthError.failed("Vault key not found; recovery is required.")
            }
            guard let data = try storage.read() else { throw CryptoEnvelopeError.invalidData }
            return (data, try VaultCrypto.decrypt(data, key: key), key)
        }.value
        try checkAuthenticationRequest(request)
        guard sessionGeneration == generation else {
            throw VaultSessionError.supersededRequest
        }
        publishOpen(loaded)
    }

    private func publishOpen(_ loaded: (Data, VaultPayload, SymmetricKey)) {
        let (data, p, k) = loaded
        self.undoEntries = []
        self.redoEntries = []
        self.key = k
        self.sensitiveKey = nil
        self.isSensitiveUnlocked = false
        self.ciphertext = data
        self.payload = p
        self.isUnlocked = true
        self.sessionGeneration = UUID()
        self.touch()
        self.startAutoLock()
    }

    /// Releases the sensitive key after user presence, then opens every item the
    /// user marked. Until this succeeds those items have no fields in memory and
    /// are therefore absent from search, the browser detail, and Quick Fill.
    public func unlockSensitiveItems(reason: String = "Open protected items") async throws {
        guard isUnlocked else { throw AuthError.failed("Vault locked") }
        guard !isSensitiveUnlocked else { return }
        let request = UUID()
        authenticationRequest = request
        do {
            try await performUnlockSensitive(request: request, reason: reason)
            lastError = nil
        } catch {
            if authenticationRequest == request {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }
    }

    private func performUnlockSensitive(request: UUID, reason: String) async throws {
        let approved = try await auth.authenticate(reason: reason)
        try checkAuthenticationRequest(request)
        guard approved else { throw AuthError.canceled }
        let sensitive: SymmetricKey
        if try keyStore.sensitiveKeyExists() {
            sensitive = try keyStore.loadSensitiveKey(
                reason: reason, context: auth.authenticatedContext())
        } else {
            // First protected item: the key is created here, under the same
            // presence requirement every later read will ask for.
            sensitive = SymmetricKey(size: .bits256)
            try keyStore.storeSensitiveKey(sensitive)
        }
        self.sensitiveKey = sensitive
        do {
            try openSealedItems()
        } catch {
            self.sensitiveKey = nil
            throw VaultSessionError.invalidData(
                "Protected items could not be opened with this key.")
        }
        self.isSensitiveUnlocked = true
        self.touch()
    }

    /// Drops the sensitive key and puts every protected item back in its sealed
    /// form. The vault itself stays open.
    public func lockSensitiveItems() {
        guard isSensitiveUnlocked else { return }
        if let current = payload {
            payload = (try? sealedForStorage(current)) ?? current
        }
        sensitiveKey = nil
        isSensitiveUnlocked = false
        undoEntries = []
        redoEntries = []
        sessionGeneration = UUID()
        auth.invalidateAuthentication()
    }

    private func checkAuthenticationRequest(_ request: UUID) throws {
        guard authenticationRequest == request else { throw VaultSessionError.supersededRequest }
        try Task.checkCancellation()
    }

    public func lock() {
        lockSensitiveItems()
        self.authenticationRequest = UUID()
        auth.invalidateAuthentication()
        self.sessionGeneration = UUID()
        self.key = nil
        self.sensitiveKey = nil
        self.isSensitiveUnlocked = false
        self.ciphertext = nil
        self.payload = nil
        self.undoEntries = []
        self.redoEntries = []
        self.isUnlocked = false
        self.stopAutoLock()
        self.onLock?()
    }

    public func touch() { lastActivity = Date() }

    /// Inactivity, sleep, and screen lock now close the protected items rather
    /// than the whole vault: everything else stays usable.
    private func startAutoLock() {
        stopAutoLock()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isSensitiveUnlocked else { return }
                let minutes = self.payload?.settings.autoLockMinutes ?? 5
                if AutoLock.shouldLock(lastActivity: self.lastActivity, now: Date(), configuredMinutes: minutes) {
                    self.lockSensitiveItems()
                }
            }
        }
        lockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func stopAutoLock() { lockTimer?.invalidate(); lockTimer = nil }
    private func registerSystemObservers() {
        stopSystemObservers()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockSensitiveItems() }
        }
        // Screen lock is delivered via distributed notifications (not guaranteed across OS versions).
        screenLockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockSensitiveItems() }
        }
    }
    private func stopSystemObservers() {
        if let t = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(t); sleepObserver = nil }
        if let t = screenLockObserver { DistributedNotificationCenter.default().removeObserver(t); screenLockObserver = nil }
    }

    // MARK: - Protected items

    /// The payload as it must reach disk: protected items carry their sealed
    /// contents and no plaintext fields. An item that is already sealed passes
    /// through untouched, so writing a vault with locked items needs no key.
    private func sealedForStorage(_ source: VaultPayload) throws -> VaultPayload {
        guard source.items.contains(where: { $0.isSensitive && $0.sealedFields == nil }) else {
            return source
        }
        guard let sensitiveKey else { throw VaultSessionError.itemsLocked }
        var sealed = source
        for index in sealed.items.indices {
            let item = sealed.items[index]
            guard item.isSensitive, item.sealedFields == nil else { continue }
            sealed.items[index].sealedFields = try SensitiveVault.seal(
                fields: item.fields, key: sensitiveKey)
            sealed.items[index].fields = []
        }
        return sealed
    }

    private func openSealedItems() throws {
        guard let sensitiveKey, var current = payload else { return }
        for index in current.items.indices {
            guard let sealed = current.items[index].sealedFields else { continue }
            current.items[index].fields = try SensitiveVault.open(sealed, key: sensitiveKey)
            current.items[index].sealedFields = nil
        }
        payload = current
    }

    // Data operations
    @discardableResult
    public func mutate<Result>(actionName: String = "Vault Change", _ update: (inout VaultPayload) throws -> Result) async throws -> Result {
        do {
            let result = try await performMutation(update, actionName: actionName)
            lastError = nil
            return result
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    /// Encoding, encryption, and the file write are the only parts that scale
    /// with vault size, and none of them need the main actor. The gate keeps two
    /// edits from racing for the same expected bytes; the writer runs them off
    /// the main thread so typing never waits for a disk.
    private func performMutation<Result>(_ update: (inout VaultPayload) throws -> Result, actionName: String) async throws -> Result {
        try Task.checkCancellation()
        await mutationGate.acquire()
        do {
            let result = try await lockedMutation(update, actionName: actionName)
            await mutationGate.release()
            return result
        } catch {
            await mutationGate.release()
            throw error
        }
    }

    private func lockedMutation<Result>(_ update: (inout VaultPayload) throws -> Result, actionName: String) async throws -> Result {
        guard isUnlocked, let k = key, var p = payload, let original = ciphertext else { throw AuthError.failed("Vault locked") }
        let previous = p
        let result = try update(&p)
        p.updatedAt = Date()
        p = try p.validated()
        let stored = try sealedForStorage(p)
        let generation = sessionGeneration
        let data = try await mutationWriter.write(
            payload: stored, key: k, to: storage, expected: original)
        // A lock that landed during the write must not be undone by publishing.
        guard isUnlocked, sessionGeneration == generation else {
            throw VaultSessionError.supersededRequest
        }
        undoEntries.append(HistoryEntry(name: actionName, payload: previous))
        if undoEntries.count > 30 { undoEntries.removeFirst() }
        redoEntries = []
        self.ciphertext = data
        // A protected item stays open in memory while the sensitive key is held;
        // `stored` is what went to disk.
        self.payload = p
        self.touch()
        return result
    }

    public func replaceContents(with imported: VaultPayload) async throws {
        let imported = try imported.validated()
        try await mutate { payload in
            payload.items = imported.items
            payload.categories = imported.categories
            payload.profiles = imported.profiles
            payload.settings = imported.settings
        }
        sessionGeneration = UUID()
        undoEntries = []
        redoEntries = []
        // Imported contents arrive sealed. Whatever was open for the previous
        // vault must not stay open for this one.
        lockSensitiveItems()
    }

    public func undo() throws { try applyHistory(undo: true) }
    public func redo() throws { try applyHistory(undo: false) }

    private func applyHistory(undo: Bool) throws {
        guard isUnlocked, let key, let payload, let ciphertext,
              let entry = (undo ? undoEntries : redoEntries).last else { throw AuthError.failed("No vault change to restore.") }
        do {
            var restored = try entry.payload.validated()
            restored.updatedAt = Date()
            let data = try VaultCrypto.encrypt(payload: try sealedForStorage(restored), key: key)
            try storage.write(data, expected: ciphertext)
            let inverse = HistoryEntry(name: entry.name, payload: payload)
            if undo {
                undoEntries.removeLast()
                redoEntries.append(inverse)
            } else {
                redoEntries.removeLast()
                undoEntries.append(inverse)
            }
            self.ciphertext = data
            self.payload = restored
            sessionGeneration = UUID()
            lastError = nil
            touch()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func recoverContents(with imported: VaultPayload) async throws -> URL? {
        guard !isUnlocked else { throw VaultSessionError.invalidData("Lock the vault before recovery.") }
        let imported = try imported.validated()
        let request = UUID()
        authenticationRequest = request
        do {
            let approved = try await auth.authenticate(reason: "Restore UniversalVault from an encrypted backup")
            try checkAuthenticationRequest(request)
            guard approved else { throw AuthError.canceled }
            let previous = try storage.read()
            let archive = try previous.map { try storage.preserveForRecovery($0) }
            let recoveryKey: SymmetricKey
            if try keyStore.keyExists() {
                recoveryKey = try keyStore.loadKey(
                    reason: "Restore vault", context: auth.authenticatedContext())
            } else {
                recoveryKey = SymmetricKey(size: .bits256)
                try keyStore.storeKey(recoveryKey)
            }
            let data = try VaultCrypto.encrypt(payload: imported, key: recoveryKey)
            try storage.write(data, expected: previous)
            key = recoveryKey
            ciphertext = data
            payload = imported
            isUnlocked = true
            sensitiveKey = nil
            isSensitiveUnlocked = false
            sessionGeneration = UUID()
            undoEntries = []
            redoEntries = []
            lastError = nil
            touch()
            startAutoLock()
            return archive
        } catch {
            if authenticationRequest == request { lastError = error.localizedDescription }
            throw error
        }
    }

    public func requirePresence(reason: String) async throws {
        let generation = sessionGeneration
        guard isUnlocked else { throw AuthError.failed("Vault locked") }
        let ok = try await auth.authenticate(reason: reason)
        guard isUnlocked, sessionGeneration == generation else { throw VaultSessionError.supersededRequest }
        try Task.checkCancellation()
        guard ok else { throw AuthError.canceled }
    }

    public struct VaultBackupEnvelope: Codable {
        public let format: String
        public let version: Int
        public let kdf: String
        public let iterations: Int
        public let salt: String
        public let sealedBox: String
    }

    nonisolated private static let backupAAD = Data("UniversalVault|backup|v1".utf8)
    nonisolated private static let minimumBackupPassphraseLength = 12
    nonisolated public static let maximumBackupSize = 64 * 1024 * 1024

    public func savePayloadToBackup(passphrase: String) throws -> Data {
        guard let payload else { throw AuthError.failed("Vault locked") }
        // Backups carry protected items in their sealed form; the backup
        // passphrase never becomes a substitute for the sensitive key.
        return try Self.exportBackup(try sealedForStorage(payload), passphrase: passphrase)
    }

    nonisolated public static func exportBackup(_ payload: VaultPayload, passphrase: String) throws -> Data {
        guard passphrase.count >= Self.minimumBackupPassphraseLength else {
            throw VaultSessionError.invalidData("Backup passphrase must be at least \(Self.minimumBackupPassphraseLength) characters.")
        }
        let p = try payload.validated()
        let salt = try Self.randomData(16)
        let iterations = 600_000
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
        let data = try envEnc.encode(env)
        guard data.count <= maximumBackupSize else {
            throw VaultSessionError.invalidData("Backup exceeds the 64 MiB limit. No backup file was written.")
        }
        return data
    }

    nonisolated public static func importBackup(_ data: Data, passphrase: String) throws -> VaultPayload {
        guard data.count <= maximumBackupSize else { throw CryptoEnvelopeError.invalidData }
        if let env = try? JSONDecoder().decode(VaultBackupEnvelope.self, from: data) {
            guard env.format == "universal-vault-backup", env.version == 1,
               env.kdf == "PBKDF2-HMAC-SHA256",
               (100_000...1_000_000).contains(env.iterations),
               env.salt.count >= 22, // enough base64 for 16-byte salt
               Data(base64Encoded: env.salt)?.count == 16,
               let salt = Data(base64Encoded: env.salt),
               let boxData = Data(base64Encoded: env.sealedBox) else { throw CryptoEnvelopeError.invalidData }
                let keyData = try deriveKey(passphrase: passphrase, salt: salt, iterations: UInt32(env.iterations))
                let k = SymmetricKey(data: keyData)
                let box = try AES.GCM.SealedBox(combined: boxData)
                let plaintext = try AES.GCM.open(box, using: k, authenticating: Self.backupAAD)
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                return try dec.decode(VaultPayload.self, from: plaintext).validated()
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
        return try dec.decode(VaultPayload.self, from: plaintext).validated()
    }

    nonisolated private static func randomData(_ n: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        guard status == errSecSuccess else { throw KeyStoreError.unexpected(status) }
        return Data(bytes)
    }

    nonisolated private static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> Data {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
            [UInt8](salt), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterations, &derived, derived.count)
        guard status == kCCSuccess else { throw CryptoEnvelopeError.decryptionFailed }
        return Data(derived)
    }
}

/// Serialises mutations inside the session. Callers queue in the order they
/// arrived, so the payload snapshot an edit is based on is never stale.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// The expensive half of a save: JSON encoding, AES-GCM, and the atomic file
/// replacement, off the main actor and serialised by the calling gate.
actor VaultMutationWriter {
    func write(
        payload: VaultPayload, key: SymmetricKey, to storage: VaultStorage, expected: Data?
    ) throws -> Data {
        let data = try VaultCrypto.encrypt(payload: payload, key: key)
        try storage.write(data, expected: expected)
        return data
    }
}

// CommonCrypto import
import CommonCrypto

public enum VaultSessionError: Error, LocalizedError {
    case invalidData(String)
    case supersededRequest
    case itemsLocked
    public var errorDescription: String? {
        switch self {
        case .invalidData(let m): return m
        case .supersededRequest: return "This authentication request was canceled by a lock or a newer request. Try again."
        case .itemsLocked: return "Protected items are locked. Unlock them with Touch ID first."
        }
    }
}
