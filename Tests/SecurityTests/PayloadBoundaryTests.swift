import Core
import CryptoKit
import XCTest

@testable import VaultSecurity

@MainActor final class PayloadBoundaryTests: XCTestCase {
  func testNewBackupWorkFactor() throws {
    let data = try VaultSession.exportBackup(
      VaultPayload(), passphrase: "synthetic-backup-passphrase")
    let envelope = try JSONDecoder().decode(VaultSession.VaultBackupEnvelope.self, from: data)
    XCTAssertEqual(envelope.iterations, 600_000)
    XCTAssertEqual(envelope.kdf, "PBKDF2-HMAC-SHA256")
  }
  func testBackupWhitespaceAndUnknownKDFHandling() throws {
    let password = "synthetic-backup-passphrase"
    let backup = try VaultSession.exportBackup(VaultPayload(), passphrase: password)
    XCTAssertNoThrow(try VaultSession.importBackup(Data(" \n".utf8) + backup, passphrase: password))
    var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
    metadata["kdf"] = "unrecognized"
    let modified = try JSONSerialization.data(withJSONObject: metadata)
    XCTAssertThrowsError(try VaultSession.importBackup(modified, passphrase: password))
  }
  func testDecryptedLegacySecretIsNormalized() throws {
    let key = SymmetricKey(size: .bits256)
    let field = VaultField(
      key: "secret", label: "Secret", type: .secret, value: .secret("synthetic"))
    let data = try VaultCrypto.encrypt(
      payload: VaultPayload(items: [VaultItem(title: "Item", fields: [field])]), key: key)
    XCTAssertEqual(
      try VaultCrypto.decrypt(data, key: key).items[0].fields[0].sensitivity, .sensitive)
  }

  func testUnlockRejectsUnsupportedSchema() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UV-boundary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try FileSystemVaultStorage(directory: directory)
    let keys = InMemoryKeyStore()
    let session = VaultSession(storage: storage, keyStore: keys, auth: TestAuth())
    try await session.createNewVault()
    session.lock()
    let key = try keys.loadKey(reason: "Synthetic test")
    try storage.write(VaultCrypto.encrypt(payload: VaultPayload(schemaVersion: 2), key: key))
    do {
      try await session.unlock()
      XCTFail("Unsupported schema must not unlock")
    } catch {
      XCTAssertFalse(session.isUnlocked)
      XCTAssertNil(session.currentPayload)
    }
  }

  func testReplacementRejectsDuplicateIDsWithoutChangingDisk() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UV-boundary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try FileSystemVaultStorage(directory: directory)
    let session = VaultSession(storage: storage, keyStore: InMemoryKeyStore(), auth: TestAuth())
    try await session.createNewVault()
    defer { session.lock() }
    let original = try storage.read()
    let item = VaultItem(title: "Duplicate")
    do {
      try await session.replaceContents(with: VaultPayload(items: [item, item]))
      XCTFail("Ambiguous identities must be rejected")
    } catch {
      XCTAssertEqual(try storage.read(), original)
      XCTAssertTrue(try XCTUnwrap(session.currentPayload).items.isEmpty)
    }
  }
}
