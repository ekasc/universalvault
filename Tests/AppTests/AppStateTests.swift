import Core
import CryptoKit
import VaultSecurity
import XCTest

@testable import App

private struct SyntheticAuth: UserPresenceAuthenticating {
  func authenticate(reason: String) async throws -> Bool { true }
}

private actor PausableAuth: UserPresenceAuthenticating {
  private var paused = false
  private var continuation: CheckedContinuation<Bool, Never>?
  func pause() { paused = true }
  func authenticate(reason: String) async throws -> Bool {
    if !paused { return true }
    return await withCheckedContinuation { continuation = $0 }
  }
  func waitForRequest() async {
    while continuation == nil { await Task.yield() }
  }
  func approve() {
    continuation?.resume(returning: true)
    continuation = nil
  }
}

private final class SyntheticKeys: VaultKeyStore, @unchecked Sendable {
  private var key: SymmetricKey?
  private var sensitive: SymmetricKey?
  func keyExists() throws -> Bool { key != nil }
  func loadKey(reason: String) throws -> SymmetricKey {
    guard let key else { throw KeyStoreError.notFound }
    return key
  }
  func storeKey(_ key: SymmetricKey) throws { self.key = key }
  func deleteKey() throws { key = nil; sensitive = nil }
  func sensitiveKeyExists() throws -> Bool { sensitive != nil }
  func loadSensitiveKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey {
    guard let sensitive else { throw KeyStoreError.notFound }
    return sensitive
  }
  func storeSensitiveKey(_ key: SymmetricKey) throws { sensitive = key }
  func deleteSensitiveKey() throws { sensitive = nil }
}

@MainActor final class AppStateTests: XCTestCase {
  func testInvalidShortcutIsRejectedBeforeOSRegistration() {
    let manager = HotKeyManager()
    XCTAssertFalse(manager.register(HotKeyShortcut(keyCode: 0, modifiers: [])))
    XCTAssertFalse(manager.isRegistered)
    XCTAssertEqual(manager.current, .default)
  }
  func testBackupFileReplacementIsPrivateAndLeavesNoTemporaryFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UV-app-backup-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("backup.uvbackup")
    try Data("old".utf8).write(to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: destination.path)
    let data = try VaultSession.exportBackup(VaultPayload(), passphrase: "synthetic-passphrase")
    try BackupTransferView.writePrivateBackup(data, to: destination)
    XCTAssertEqual(try Data(contentsOf: destination), data)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path), ["backup.uvbackup"])
    XCTAssertThrowsError(try BackupTransferView.writePrivateBackup(data, to: directory))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path), ["backup.uvbackup"])
  }
  func testFieldChangedDuringActualAuthenticationCancelsInsertion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UV-app-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let auth = PausableAuth()
    let session = VaultSession(
      storage: try FileSystemVaultStorage(directory: directory), keyStore: SyntheticKeys(),
      auth: auth)
    defer { session.lock() }
    let state = AppState(session: session, systemIntegration: false)
    try await session.createNewVault()
    try await session.mutate {
      $0.items.append(
        VaultItem(
          title: "Synthetic",
          fields: [
            VaultField(key: "name", label: "Name", sensitivity: .sensitive)
          ]))
    }
    state.refreshResults()
    await auth.pause()
    state.insertSelected()
    await auth.waitForRequest()
    try await session.mutate { $0.items[0].fields[0].sensitivity = .critical }
    await auth.approve()
    for _ in 0..<100 where state.errorMessage == nil { await Task.yield() }
    XCTAssertEqual(state.errorMessage, "Insertion canceled.")
  }
  func testLockClearsActualAppSearchState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UV-app-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = VaultSession(
      storage: try FileSystemVaultStorage(directory: directory), keyStore: SyntheticKeys(),
      auth: SyntheticAuth())
    let state = AppState(session: session, systemIntegration: false)
    try await session.createNewVault()
    try await session.mutate {
      $0.items.append(
        VaultItem(title: "Synthetic", fields: [VaultField(key: "name", label: "Name")]))
    }
    state.paletteQuery = "Name"
    state.refreshResults()
    XCTAssertEqual(state.paletteResults.count, 1)
    state.showPalette = true
    session.lock()
    XCTAssertTrue(state.paletteQuery.isEmpty)
    XCTAssertTrue(state.paletteResults.isEmpty)
    XCTAssertFalse(state.showPalette)
  }

  /// Sealing an item removes its fields from the payload. The palette's prepared
  /// index is keyed by the payload version, which does not change when items are
  /// sealed, so a stale index would keep serving protected values after locking.
  func testLockedItemLeavesTheSearchIndex() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UV-app-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = VaultSession(
      storage: try FileSystemVaultStorage(directory: directory), keyStore: SyntheticKeys(),
      auth: SyntheticAuth())
    defer { session.lock() }
    let state = AppState(session: session, systemIntegration: false)
    try await session.createNewVault()
    try await session.unlockSensitiveItems()
    try await session.mutate {
      $0.items.append(
        VaultItem(
          title: "Bank",
          fields: [VaultField(key: "pin", label: "PIN", type: .secret, value: .secret("1234"))],
          isSensitive: true))
    }
    state.paletteQuery = "PIN"
    state.refreshResults()
    XCTAssertEqual(state.paletteResults.count, 1, "An unlocked protected field is searchable")

    session.lockSensitiveItems()
    state.refreshResults()
    XCTAssertTrue(
      state.paletteResults.isEmpty,
      "A locked field must not survive in the search index")
  }

  func testStaleSelectionIsRejectedByActualInsertAction() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UV-app-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = VaultSession(
      storage: try FileSystemVaultStorage(directory: directory), keyStore: SyntheticKeys(),
      auth: SyntheticAuth())
    defer { session.lock() }
    let state = AppState(session: session, systemIntegration: false)
    try await session.createNewVault()
    try await session.mutate {
      $0.items.append(
        VaultItem(title: "Synthetic", fields: [VaultField(key: "name", label: "Name")]))
    }
    state.refreshResults()
    try await session.mutate { $0.items[0].fields[0].sensitivity = .critical }
    state.insertSelected()
    XCTAssertEqual(state.errorMessage, "This field changed. Select it again before inserting.")
    XCTAssertEqual(state.paletteResults[0].field.sensitivity, .critical)
  }
}
