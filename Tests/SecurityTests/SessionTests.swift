import XCTest
import Core
import VaultSecurity
import CryptoKit
import Combine

/// Covers the session-level outcomes the UI reads directly: `lastError` for
/// failed create/unlock, and payload/generation invalidation on lock.
@MainActor final class SessionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() async throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try await super.tearDown()
    }

    /// Returns a session bound to a fresh vault directory. Pass an existing
    /// `directory` to simulate a restart against the same on-disk vault.
    private func makeSession(auth: UserPresenceAuthenticating,
                             keyStore: VaultKeyStore = InMemoryKeyStore(),
                             directory: URL? = nil) throws -> VaultSession {
        let url: URL
        if let directory {
            url = directory
        } else {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("UniversalVaultTests-\(UUID().uuidString)", isDirectory: true)
            temporaryDirectories.append(url)
        }
        let storage = try FileSystemVaultStorage(directory: url)
        return VaultSession(storage: storage, keyStore: keyStore, auth: auth)
    }

    /// Creation is the one identity-establishing action and it no longer asks
    /// for presence, so a refusing authenticator must never be consulted.
    func testCreationNeedsNoPresence() async throws {
        let session = try makeSession(auth: FalseAuth())
        try await session.createNewVault()
        XCTAssertTrue(session.isUnlocked)
        XCTAssertTrue(session.existsVault())
        XCTAssertNil(session.lastError)
    }

    /// The vault key no longer asks for presence, which is what lets the app open
    /// at launch. Protected items are the only surface that authenticates, so a
    /// rejecting authenticator must still open the vault and then refuse them.
    func testFailedProtectedUnlockRecordsLastError() async throws {
        let keyStore = InMemoryKeyStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalVaultTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)

        let first = try makeSession(auth: TestAuth(), keyStore: keyStore, directory: directory)
        try await first.createNewVault()
        try await first.unlockSensitiveItems()
        try await first.mutate { $0.items.append(VaultItem(title: "Card", isSensitive: true)) }
        first.lock()
        XCTAssertNil(first.lastError)

        let second = try makeSession(auth: FalseAuth(), keyStore: keyStore, directory: directory)
        try await second.unlock()
        XCTAssertTrue(second.isUnlocked, "Opening the vault must not require presence")
        XCTAssertNil(second.lastError)
        do {
            try await second.unlockSensitiveItems()
            XCTFail("Protected items should fail with rejecting authentication")
        } catch {
            XCTAssertNotNil(second.lastError)
            XCTAssertFalse(second.isSensitiveUnlocked)
            XCTAssertEqual(second.lockedItemCount, 1)
        }
    }

    func testSuccessfulCreateLeavesNoError() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()
        XCTAssertNil(session.lastError)
        XCTAssertTrue(session.isUnlocked)
    }

    func testErrorFromSecondCreateIsRecorded() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()
        XCTAssertNil(session.lastError)
        do {
            try await session.createNewVault()
            XCTFail("Creating a second vault must fail")
        } catch {
            XCTAssertNotNil(session.lastError)
        }
    }

    func testLockClearsPayloadAndAdvancesGeneration() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()
        let generation = session.sessionGeneration
        XCTAssertNotNil(session.currentPayload)

        session.lock()
        XCTAssertFalse(session.isUnlocked)
        XCTAssertNil(session.currentPayload, "decrypted payload must not survive a lock")
        XCTAssertNotEqual(session.sessionGeneration, generation,
                          "async insertion work keys off the generation and must be invalidated")
    }

    /// Views read `session.currentPayload`. `isUnlocked` and `sessionGeneration`
    /// do not change when an item is edited, so the payload itself must notify.
    func testMutateNotifiesObservers() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()

        let notified = expectation(description: "payload mutation notifies observers")
        notified.assertForOverFulfill = false
        let token = session.objectWillChange.sink { _ in notified.fulfill() }
        defer { token.cancel() }

        try await session.mutate { payload in
            payload.items.append(VaultItem(title: "Edited"))
        }

        await fulfillment(of: [notified], timeout: 2)
    }

    func testThrowingEditDoesNotPublishOrWritePartialChanges() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()
        defer { session.lock() }
        let before = try Data(contentsOf: session.storageURL)

        do {
            try await session.mutate { payload in
                payload.items.append(VaultItem(title: "Must not persist"))
                throw VaultEditError.emptyName
            }
            XCTFail("A rejected edit must fail")
        } catch {
            XCTAssertEqual(error as? VaultEditError, .emptyName)
        }
        XCTAssertTrue(try XCTUnwrap(session.currentPayload).items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: session.storageURL), before)
    }

    func testEditReturnsIdentityAfterPersistence() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()
        defer { session.lock() }
        let id = try await session.mutate { try $0.addCategory(name: "New category") }
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.currentPayload?.categories.first?.id, id)
    }

    func testEditorSavesValidFieldsWhenTitleIsCleared() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()
        defer { session.lock() }
        let original = VaultItem(title: "Passport", fields: [VaultField(key: "number", label: "Number")])
        try await session.mutate { $0.items.append(original) }
        var draft = original
        draft.title = ""
        draft.fields[0].value = .text("Synthetic value")
        try await session.mutate { payload in
            let clean = try XCTUnwrap(payload.itemForSaving(draft, replacing: original))
            payload.updateItem(original.id) { $0 = clean }
        }
        session.lock()
        try await session.unlock()
        let restored = try XCTUnwrap(session.currentPayload?.items.first)
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.fields[0].value, .text("Synthetic value"))
    }

    func testReplacementInvalidatesPendingActionsAndPersistsContents() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()
        defer { session.lock() }
        let generation = session.sessionGeneration
        let category = VaultCategory(name: "Imported")
        try await session.replaceContents(with: VaultPayload(categories: [category]))
        XCTAssertNotEqual(session.sessionGeneration, generation)
        XCTAssertEqual(session.currentPayload?.categories, [category])
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.currentPayload?.categories, [category])
    }

    func testRejectedReplacementDoesNotInvalidatePendingActions() async throws {
        let session = try makeSession(auth: TestAuth())
        try await session.createNewVault()
        defer { session.lock() }
        let generation = session.sessionGeneration
        let bytes = try Data(contentsOf: session.storageURL)
        do {
            try await session.replaceContents(with: VaultPayload(items: [VaultItem(title: "")]))
            XCTFail("Invalid replacement must fail")
        } catch {
            XCTAssertEqual(session.sessionGeneration, generation)
        }
        XCTAssertTrue(try XCTUnwrap(session.currentPayload).items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: session.storageURL), bytes)
    }

    func testUnlockRestoresPersistedPayload() async throws {
        let keyStore = InMemoryKeyStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalVaultTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)

        let first = try makeSession(auth: TestAuth(), keyStore: keyStore, directory: directory)
        try await first.createNewVault()
        try await first.mutate { p in p.items.append(VaultItem(title: "Persisted")) }
        first.lock()

        let second = try makeSession(auth: TestAuth(), keyStore: keyStore, directory: directory)
        try await second.unlock()
        XCTAssertNil(second.lastError)
        XCTAssertEqual(second.currentPayload?.items.first?.title, "Persisted")
    }
}
