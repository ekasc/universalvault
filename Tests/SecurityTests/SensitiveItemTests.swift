import XCTest
import Core
import VaultSecurity
import CryptoKit

/// An authenticator that records whether it was asked at all, so "this path does
/// not prompt" is proved rather than assumed.
private actor CountingAuth: UserPresenceAuthenticating {
    private var calls = 0
    func authenticate(reason: String) async throws -> Bool {
        calls += 1
        return true
    }
    func callCount() -> Int { calls }
}

/// Items the user marks are sealed with a second key. These cover the property
/// that matters: the plaintext is not in the vault file and not in memory while
/// the item is locked.
@MainActor final class SensitiveItemTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() async throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try await super.tearDown()
    }

    private func makeSession(
        auth: UserPresenceAuthenticating = TestAuth(),
        keyStore: InMemoryKeyStore = InMemoryKeyStore()
    ) throws -> (VaultSession, InMemoryKeyStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalVaultSensitive-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let session = VaultSession(
            storage: try FileSystemVaultStorage(directory: directory),
            keyStore: keyStore,
            auth: auth)
        return (session, keyStore)
    }

    private let secret = "synthetic-protected-1234"

    private var protectedItem: VaultItem {
        VaultItem(
            title: "Bank",
            fields: [
                VaultField(key: "pin", label: "PIN", type: .secret, value: .secret(secret))
            ],
            isSensitive: true)
    }

    func testProtectedItemIsSealedAtRestAndInMemoryWhenLocked() async throws {
        let (session, keys) = try makeSession()
        defer { session.lock() }
        try await session.createNewVault()
        try await session.unlockSensitiveItems()
        try await session.mutate { $0.items.append(protectedItem) }

        // While the sensitive key is held the item is usable.
        XCTAssertEqual(session.currentPayload?.items.first?.fields.count, 1)
        XCTAssertFalse(session.currentPayload?.items.first?.isLocked ?? true)

        // The file never carries the plaintext, only the sealed fields.
        let vaultKey = try keys.loadKey(reason: "Test read")
        let stored = try VaultCrypto.decrypt(try XCTUnwrap(try session.storageBytes()), key: vaultKey)
        let storedItem = try XCTUnwrap(stored.items.first)
        XCTAssertTrue(storedItem.fields.isEmpty)
        XCTAssertNotNil(storedItem.sealedFields)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(stored), as: UTF8.self).contains(secret))

        session.lockSensitiveItems()
        XCTAssertFalse(session.isSensitiveUnlocked)
        XCTAssertTrue(session.currentPayload?.items.first?.isLocked ?? false)
        XCTAssertEqual(session.currentPayload?.items.first?.fields.count, 0)
        XCTAssertTrue(session.isUnlocked, "Locking protected items must keep the vault open")
    }

    func testUnlockingRestoresFieldsAndLockingAgainSealsThem() async throws {
        let (session, _) = try makeSession()
        defer { session.lock() }
        try await session.createNewVault()
        try await session.unlockSensitiveItems()
        try await session.mutate { $0.items.append(protectedItem) }
        session.lockSensitiveItems()

        try await session.unlockSensitiveItems()
        XCTAssertTrue(session.isSensitiveUnlocked)
        let field = try XCTUnwrap(session.currentPayload?.items.first?.fields.first)
        XCTAssertEqual(field.value, .secret(secret))

        session.lockSensitiveItems()
        XCTAssertEqual(session.currentPayload?.items.first?.fields.count, 0)
    }

    /// Marking an item protected is refused unless the sensitive key is in hand.
    func testProtectingAnItemRequiresTheSensitiveKey() async throws {
        let (session, _) = try makeSession()
        defer { session.lock() }
        try await session.createNewVault()
        do {
            try await session.mutate { $0.items.append(protectedItem) }
            XCTFail("A protected item must not be written without the sensitive key")
        } catch {
            guard case VaultSessionError.itemsLocked = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try XCTUnwrap(session.currentPayload).items.isEmpty)
    }

    func testBackupCarriesProtectedItemsSealed() async throws {
        let (session, _) = try makeSession()
        defer { session.lock() }
        try await session.createNewVault()
        try await session.unlockSensitiveItems()
        try await session.mutate { $0.items.append(protectedItem) }

        let backup = try session.savePayloadToBackup(passphrase: "synthetic-passphrase")
        let imported = try VaultSession.importBackup(backup, passphrase: "synthetic-passphrase")
        let item = try XCTUnwrap(imported.items.first)
        XCTAssertTrue(item.isSensitive)
        XCTAssertTrue(item.isLocked)
        XCTAssertTrue(item.fields.isEmpty)
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains(secret))
    }

    /// Exporting from an *unlocked* session must not put protected fields in the
    /// passphrase-only backup. The UI calls `payloadForBackup` for exactly this.
    func testExportFromUnlockedSessionKeepsProtectedItemsSealed() async throws {
        let (session, _) = try makeSession()
        defer { session.lock() }
        try await session.createNewVault()
        try await session.unlockSensitiveItems()
        try await session.mutate { $0.items.append(protectedItem) }
        XCTAssertEqual(session.currentPayload?.items.first?.fields.count, 1)

        let sealed = try session.payloadForBackup()
        XCTAssertEqual(sealed.items.first?.fields.count, 0)
        XCTAssertNotNil(sealed.items.first?.sealedFields)

        let backup = try VaultSession.exportBackup(sealed, passphrase: "synthetic-passphrase")
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains(secret))
        let imported = try VaultSession.importBackup(backup, passphrase: "synthetic-passphrase")
        XCTAssertTrue(imported.items.first?.isLocked ?? false)
    }

    /// A backup written before the export sealed its payload can carry protected
    /// fields in the clear. Recovery must seal them rather than store plaintext.
    func testRecoverySealsProtectedItemsFromAnOlderBackup() async throws {
        let legacy = VaultPayload(items: [protectedItem])
        let backup = try VaultSession.exportBackup(legacy, passphrase: "synthetic-passphrase")
        let imported = try VaultSession.importBackup(backup, passphrase: "synthetic-passphrase")
        XCTAssertEqual(imported.items.first?.fields.count, 1, "fixture must start unsealed")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalVaultReclaim-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let keys = InMemoryKeyStore()
        let session = VaultSession(
            storage: try FileSystemVaultStorage(directory: directory),
            keyStore: keys,
            auth: TestAuth())
        defer { session.lock() }

        _ = try await session.recoverContents(with: imported)

        let stored = try XCTUnwrap(session.currentPayload?.items.first)
        XCTAssertNotNil(stored.sealedFields)
        XCTAssertTrue(stored.fields.isEmpty)
        XCTAssertTrue(stored.isLocked)
        XCTAssertFalse(session.isSensitiveUnlocked)
    }

    /// The launch path must not touch user presence: that is the whole point of
    /// the vault opening by itself.
    func testOpeningAtLaunchNeverAsksForPresence() async throws {
        let keyStore = InMemoryKeyStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalVaultLaunch-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let first = VaultSession(
            storage: try FileSystemVaultStorage(directory: directory),
            keyStore: keyStore,
            auth: TestAuth())
        try await first.createNewVault()
        try await first.unlockSensitiveItems()
        try await first.mutate { $0.items.append(protectedItem) }
        first.lock()

        let auth = CountingAuth()
        let second = VaultSession(
            storage: try FileSystemVaultStorage(directory: directory),
            keyStore: keyStore,
            auth: auth)
        defer { second.lock() }
        await second.openIfAvailable()

        XCTAssertTrue(second.isUnlocked)
        XCTAssertFalse(second.isSensitiveUnlocked)
        XCTAssertNil(second.lastError)
        let calls = await auth.callCount()
        XCTAssertEqual(calls, 0, "Opening the vault must not prompt")
        // The protected item is present but sealed.
        XCTAssertTrue(second.currentPayload?.items.first?.isLocked ?? false)
        XCTAssertEqual(second.lockedItemCount, 1)
    }

    /// A payload written before per-item protection still decodes, with the item
    /// staying unprotected.
    func testLegacyItemWithoutProtectionKeysDecodes() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Old","tags":[],"fields":[],\
        "createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","sortOrder":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(VaultItem.self, from: Data(legacy.utf8))
        XCTAssertFalse(item.isSensitive)
        XCTAssertNil(item.sealedFields)
        XCTAssertFalse(item.isLocked)
    }
}

extension VaultSession {
    /// The bytes currently on disk, for tests that inspect what was persisted.
    func storageBytes() throws -> Data? {
        try Data(contentsOf: storageURL)
    }
}
