import XCTest
import Core
import VaultSecurity
import CryptoKit
import CommonCrypto

final class TestAuth: UserPresenceAuthenticating, @unchecked Sendable {
    func authenticate(reason: String) async throws -> Bool { true }
}
final class FalseAuth: UserPresenceAuthenticating, @unchecked Sendable {
    func authenticate(reason: String) async throws -> Bool { false }
}

final class InMemoryKeyStore: VaultKeyStore, @unchecked Sendable {
    private var data: Data?
    private var sensitive: Data?
    func keyExists() throws -> Bool { data != nil }
    func loadKey(reason: String) throws -> SymmetricKey {
        guard let d = data else { throw KeyStoreError.notFound }
        return SymmetricKey(data: d)
    }
    func storeKey(_ key: SymmetricKey) throws {
        data = key.withUnsafeBytes { Data($0) }
    }
    func deleteKey() throws { data = nil; sensitive = nil }
    func sensitiveKeyExists() throws -> Bool { sensitive != nil }
    func loadSensitiveKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey {
        guard let sensitive else { throw KeyStoreError.notFound }
        return SymmetricKey(data: sensitive)
    }
    func storeSensitiveKey(_ key: SymmetricKey) throws {
        sensitive = key.withUnsafeBytes { Data($0) }
    }
    func deleteSensitiveKey() throws { sensitive = nil }
}

@MainActor final class CryptoTests: XCTestCase {
    func testRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        var payload = VaultPayload()
        payload.items.append(VaultItem(title: "X", fields: [VaultField(key:"a",label:"A",type:.text,value:.text("secret"))]))
        let data = try VaultCrypto.encrypt(payload: payload, key: key)
        let dec = try VaultCrypto.decrypt(data, key: key)
        XCTAssertEqual(dec.items.first?.title, "X")
    }
    func testTamper() throws {
        let key = SymmetricKey(size: .bits256)
        let data = try VaultCrypto.encrypt(payload: VaultPayload(), key: key)
        var tampered = data
        tampered[tampered.count-1] ^= 0xFF
        XCTAssertThrowsError(try VaultCrypto.decrypt(tampered, key: key))
    }
    func testWrongKey() throws {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        let data = try VaultCrypto.encrypt(payload: VaultPayload(), key: k1)
        XCTAssertThrowsError(try VaultCrypto.decrypt(data, key: k2))
    }
    @MainActor func testBackupRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = try FileSystemVaultStorage(directory: url)
        let session = VaultSession(storage: storage, keyStore: InMemoryKeyStore(), auth: TestAuth())
        defer { session.lock() }
        try await session.createNewVault()
        try await session.mutate { p in
            p.items.append(VaultItem(title: "B"))
        }
        let backup = try session.savePayloadToBackup(passphrase: "passphrase1234")
        let imported = try VaultSession.importBackup(backup, passphrase: "passphrase1234")
        XCTAssertEqual(imported.items.first?.title, "B")
        XCTAssertThrowsError(try VaultSession.importBackup(backup, passphrase: "wrong"))
    }
    func testUnsupportedVersion() throws {
        let key = SymmetricKey(size: .bits256)
        let data = try VaultCrypto.encrypt(payload: VaultPayload(), key: key)
        // corrupt version in json outer
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["formatVersion"] = 999
        let bad = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try VaultCrypto.decrypt(bad, key: key))
    }

    @MainActor func testCreateVaultTwiceThrows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = try FileSystemVaultStorage(directory: url)
        let session = VaultSession(storage: storage, keyStore: InMemoryKeyStore(), auth: TestAuth())
        try await session.createNewVault()
        do {
            try await session.createNewVault()
            XCTFail("Second creation should fail")
        } catch {
            // expected
        }
    }

    @MainActor func testShortBackupPassphraseThrows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = try FileSystemVaultStorage(directory: url)
        let session = VaultSession(storage: storage, keyStore: InMemoryKeyStore(), auth: TestAuth())
        try await session.createNewVault()
        XCTAssertThrowsError(try session.savePayloadToBackup(passphrase: "short"))
    }

    @MainActor func testExistingKeyWithoutVaultThrows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = try FileSystemVaultStorage(directory: url)
        let keyStore = InMemoryKeyStore()
        try keyStore.storeKey(SymmetricKey(size: .bits256))
        let session = VaultSession(storage: storage, keyStore: keyStore, auth: TestAuth())
        do {
            try await session.createNewVault()
            XCTFail("Creation with orphaned key should fail")
        } catch let e as VaultSession.CreationStateError {
            XCTAssertEqual(e, .keyExistsWithoutVault)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(try keyStore.keyExists())
    }

    func testBackupRejectsExtremeIterations() throws {
        let dict: [String: Any] = [
            "format": "universal-vault-backup",
            "version": 1,
            "kdf": "PBKDF2-HMAC-SHA256",
            "iterations": 10_000_000,
            "salt": Data(repeating: 0, count: 16).base64EncodedString(),
            "sealedBox": Data(repeating: 0, count: 16).base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertThrowsError(try VaultSession.importBackup(data, passphrase: "passphrase1234"))
    }



    /// Creating a vault no longer authenticates, so even an authenticator that
    /// refuses everything must not be consulted.
    @MainActor func testCreateVaultNeedsNoPresence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = try FileSystemVaultStorage(directory: url)
        let session = VaultSession(storage: storage, keyStore: InMemoryKeyStore(), auth: FalseAuth())
        try await session.createNewVault()
        XCTAssertTrue(session.isUnlocked)
        XCTAssertTrue(storage.exists())
        XCTAssertNil(session.lastError)
    }

    @MainActor func testUnlockNeedsNoPresenceButProtectedItemsDo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = try FileSystemVaultStorage(directory: url)
        let keyStore = InMemoryKeyStore()
        let first = VaultSession(storage: storage, keyStore: keyStore, auth: TestAuth())
        try await first.createNewVault()
        first.lock()
        let second = VaultSession(storage: storage, keyStore: keyStore, auth: FalseAuth())
        try await second.unlock()
        XCTAssertTrue(second.isUnlocked, "The vault key opens without presence")
        do {
            try await second.unlockSensitiveItems()
            XCTFail("Protected items must require presence")
        } catch {
            // expected
        }
        XCTAssertFalse(second.isSensitiveUnlocked)
    }

}
