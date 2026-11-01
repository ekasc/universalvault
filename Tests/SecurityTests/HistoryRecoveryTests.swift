import Core
import XCTest

@testable import VaultSecurity

@MainActor final class HistoryRecoveryTests: XCTestCase {
  private func withSession(
    _ body: (VaultSession, FileSystemVaultStorage, InMemoryKeyStore) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UV-history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try FileSystemVaultStorage(directory: directory)
    let keys = InMemoryKeyStore()
    let session = VaultSession(storage: storage, keyStore: keys, auth: TestAuth())
    defer { session.lock() }
    try await body(session, storage, keys)
  }

  func testUndoRedoPersistAndLockClearsHistory() async throws {
    try await withSession { session, _, _ in
      try await session.createNewVault()
      try await session.mutate(actionName: "Add Item") {
        $0.items.append(VaultItem(title: "Synthetic"))
      }
      XCTAssertTrue(session.canUndo)
      let generation = session.sessionGeneration
      try await session.undo()
      XCTAssertTrue(try XCTUnwrap(session.currentPayload).items.isEmpty)
      XCTAssertNotEqual(session.sessionGeneration, generation)
      XCTAssertTrue(session.canRedo)
      try await session.redo()
      XCTAssertEqual(session.currentPayload?.items.first?.title, "Synthetic")
      session.lock()
      XCTAssertFalse(session.canUndo)
      XCTAssertFalse(session.canRedo)
      try await session.unlock()
      XCTAssertEqual(session.currentPayload?.items.first?.title, "Synthetic")
      XCTAssertFalse(session.canUndo)
    }
  }

  func testFailedUndoPreservesHistoryAndDisk() async throws {
    try await withSession { session, storage, _ in
      try await session.createNewVault()
      try await session.mutate { $0.items.append(VaultItem(title: "Synthetic")) }
      let external = Data("external replacement".utf8)
      try storage.write(external)
      do {
        try await session.undo()
        XCTFail("Undo must fail when the file was replaced underneath it")
      } catch {}
      XCTAssertTrue(session.canUndo)
      XCTAssertFalse(session.canRedo)
      XCTAssertEqual(try storage.read(), external)
      XCTAssertEqual(session.currentPayload?.items.count, 1)
    }
  }

  func testRecoveryPreservesOriginalAndRestoresIndependentBackup() async throws {
    try await withSession { session, storage, keys in
      try await session.createNewVault()
      let original = try XCTUnwrap(storage.read())
      session.lock()
      try keys.deleteKey()
      let imported = VaultPayload(items: [VaultItem(title: "Recovered")])
      let recoveryArchive = try await session.recoverContents(with: imported)
      let archive = try XCTUnwrap(recoveryArchive)
      XCTAssertEqual(try Data(contentsOf: archive), original)
      XCTAssertEqual(
        (try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions]
          as? NSNumber)?.intValue, 0o600)
      XCTAssertEqual(session.currentPayload?.items.first?.title, "Recovered")
      session.lock()
      try await session.unlock()
      XCTAssertEqual(session.currentPayload?.items.first?.title, "Recovered")
    }
  }

  func testRecoveryCreatesFirstKeyWhenMachineHasNoVaultOrKey() async throws {
    try await withSession { session, storage, keys in
      XCTAssertFalse(storage.exists())
      XCTAssertFalse(try keys.keyExists())
      let imported = VaultPayload(items: [VaultItem(title: "First run recovery")])
      let archive = try await session.recoverContents(with: imported)
      XCTAssertNil(archive, "There is no previous encrypted file to preserve.")
      XCTAssertTrue(session.isUnlocked)
      XCTAssertTrue(try keys.keyExists())
      XCTAssertEqual(try VaultSession.importBackup(
        try session.savePayloadToBackup(passphrase: "synthetic-backup-passphrase"),
        passphrase: "synthetic-backup-passphrase").items.first?.title, "First run recovery")
      session.lock()
      try await session.unlock()
      XCTAssertEqual(session.currentPayload?.items.first?.title, "First run recovery")
    }
  }

  func testRecoveryIsRejectedWhileUnlocked() async throws {
    try await withSession { session, _, _ in
      try await session.createNewVault()
      do {
        _ = try await session.recoverContents(with: VaultPayload())
        XCTFail("Recovery must require a locked vault.")
      } catch {
        XCTAssertEqual(session.currentPayload?.items.isEmpty, true)
      }
    }
  }

  func testBackupReplacementClearsUndoSoReplacedDataCannotReturn() async throws {
    try await withSession { session, _, _ in
      try await session.createNewVault()
      try await session.mutate { $0.items.append(VaultItem(title: "Old")) }
      try await session.replaceContents(with: VaultPayload(items: [VaultItem(title: "New")]))
      XCTAssertFalse(session.canUndo)
      XCTAssertFalse(session.canRedo)
    }
  }
}
