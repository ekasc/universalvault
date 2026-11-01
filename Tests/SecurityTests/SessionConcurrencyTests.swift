import XCTest
import Core
import VaultSecurity

private struct RejectingSessionStorage: VaultStorage {
    let url = URL(fileURLWithPath: "/unused-mock-vault")
    func read() throws -> Data? { nil }
    func write(_ data: Data) throws { XCTFail("Session writes must use CAS") }
    func write(_ data: Data, expected: Data?) throws {
        XCTAssertNil(expected)
        throw VaultStorageError.conflict
    }
    func exists() -> Bool { false }
}

private actor SuspendedAuth: UserPresenceAuthenticating {
    private var requests: [Int: CheckedContinuation<Bool, any Error>] = [:]
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func authenticate(reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            count += 1
            requests[count] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func finish(_ request: Int, granted: Bool = true) {
        requests.removeValue(forKey: request)?.resume(returning: granted)
    }
}

/// Slows the CAS write so a lock can land while it is in flight.
private final class SlowWriteStorage: VaultStorage, @unchecked Sendable {
    private let inner: VaultStorage
    private let delay: TimeInterval

    init(_ inner: VaultStorage, delay: TimeInterval = 0.25) {
        self.inner = inner
        self.delay = delay
    }

    var url: URL { inner.url }
    func read() throws -> Data? { try inner.read() }
    func write(_ data: Data) throws { try inner.write(data) }
    func write(_ data: Data, expected: Data?) throws {
        Thread.sleep(forTimeInterval: delay)
        try inner.write(data, expected: expected)
    }
    func preserveForRecovery(_ expected: Data) throws -> URL {
        try inner.preserveForRecovery(expected)
    }
    func exists() -> Bool { inner.exists() }
}

@MainActor final class SessionConcurrencyTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SessionConcurrency-\(UUID())")
    }

    func testLockWhileProtectedUnlockAuthenticatesLeavesItemsSealed() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try FileSystemVaultStorage(directory: directory)
        let keys = InMemoryKeyStore()
        let setup = VaultSession(storage: storage, keyStore: keys, auth: TestAuth())
        try await setup.createNewVault()
        try await setup.unlockSensitiveItems()
        try await setup.mutate {
            $0.items.append(VaultItem(title: "Card",
                                      fields: [VaultField(key: "number", label: "Number")],
                                      isSensitive: true))
        }
        setup.lock()
        let auth = SuspendedAuth()
        let session = VaultSession(storage: storage, keyStore: keys, auth: auth)
        defer { session.lock() }
        try await session.unlock()
        let pending = Task { try await session.unlockSensitiveItems() }
        await auth.waitForRequests(1)
        session.lock()
        let generation = session.sessionGeneration
        await auth.finish(1)
        do {
            try await pending.value
            XCTFail("A lock must reject a pending protected unlock")
        } catch {}
        XCTAssertFalse(session.isUnlocked)
        XCTAssertFalse(session.isSensitiveUnlocked)
        XCTAssertNil(session.currentPayload)
        XCTAssertEqual(session.sessionGeneration, generation)
    }

    func testOlderUnlockCannotRepublishAfterNewerUnlock() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try FileSystemVaultStorage(directory: directory)
        let keys = InMemoryKeyStore()
        let setup = VaultSession(storage: storage, keyStore: keys, auth: TestAuth())
        try await setup.createNewVault()
        try await setup.unlockSensitiveItems()
        try await setup.mutate {
            $0.items.append(VaultItem(title: "Card",
                                      fields: [VaultField(key: "number", label: "Number")],
                                      isSensitive: true))
        }
        setup.lock()
        let auth = SuspendedAuth()
        let session = VaultSession(storage: storage, keyStore: keys, auth: auth)
        defer { session.lock() }
        try await session.unlock()
        let older = Task { try await session.unlockSensitiveItems() }
        await auth.waitForRequests(1)
        let newer = Task { try await session.unlockSensitiveItems() }
        await auth.waitForRequests(2)
        await auth.finish(2)
        try await newer.value
        await auth.finish(1)
        do {
            try await older.value
            XCTFail("Superseded protected unlock must fail")
        } catch {
            guard case VaultSessionError.supersededRequest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(session.isSensitiveUnlocked)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(session.currentPayload?.items.first?.fields.count, 1)
    }

    func testTaskCancellationDuringUnlockDoesNotPublishPayload() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try FileSystemVaultStorage(directory: directory)
        let keys = InMemoryKeyStore()
        let setup = VaultSession(storage: storage, keyStore: keys, auth: TestAuth())
        try await setup.createNewVault()
        try await setup.unlockSensitiveItems()
        try await setup.mutate {
            $0.items.append(VaultItem(title: "Card",
                                      fields: [VaultField(key: "number", label: "Number")],
                                      isSensitive: true))
        }
        setup.lock()
        let auth = SuspendedAuth()
        let session = VaultSession(storage: storage, keyStore: keys, auth: auth)
        defer { session.lock() }
        try await session.unlock()
        let pending = Task { try await session.unlockSensitiveItems() }
        await auth.waitForRequests(1)
        pending.cancel()
        await auth.finish(1)
        do {
            try await pending.value
            XCTFail("Canceled protected unlock must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNotNil(session.lastError)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertFalse(session.isSensitiveUnlocked)
        XCTAssertEqual(session.currentPayload?.items.first?.fields.count, 0)
    }

    /// A seal that lands while a write is in flight must not leave the in-memory
    /// CAS baseline behind the disk: every later save would be a false conflict.
    func testSealDuringWriteKeepsDiskAndMemoryInStep() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryKeyStore()
        let session = VaultSession(
            storage: SlowWriteStorage(try FileSystemVaultStorage(directory: directory)),
            keyStore: keys, auth: TestAuth())
        defer { session.lock() }
        try await session.createNewVault()
        try await session.unlockSensitiveItems()
        try await session.mutate {
            $0.items.append(
                VaultItem(
                    title: "Card",
                    fields: [VaultField(key: "pin", label: "PIN", value: .text("1234"))],
                    isSensitive: true))
        }

        let pending = Task { try await session.mutate { $0.items[0].title = "Card 2" } }
        try await Task.sleep(for: .milliseconds(80))
        session.lockSensitiveItems()
        do {
            try await pending.value
            XCTFail("A sealed session must not publish the pre-lock draft")
        } catch {}

        // The bug left `ciphertext` at the pre-write bytes, so this threw conflict.
        try await session.mutate { $0.items[0].title = "Card 3" }
        XCTAssertEqual(session.currentPayload?.items.first?.title, "Card 3")
        XCTAssertTrue(session.currentPayload?.items.first?.isLocked ?? false)
    }

    /// Undo takes the same gate as an edit, so a save in flight delays it instead
    /// of failing with "changed in another session".
    func testUndoDuringWriteWaitsInsteadOfConflicting() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession(
            storage: SlowWriteStorage(try FileSystemVaultStorage(directory: directory)),
            keyStore: InMemoryKeyStore(), auth: TestAuth())
        defer { session.lock() }
        try await session.createNewVault()
        try await session.mutate { $0.items.append(VaultItem(title: "First")) }

        let pending = Task { try await session.mutate { $0.items.append(VaultItem(title: "Second")) } }
        try await Task.sleep(for: .milliseconds(80))
        try await session.undo()
        _ = try? await pending.value

        XCTAssertNil(session.lastError)
        XCTAssertFalse(session.currentPayload?.items.contains { $0.title == "Second" } ?? true)
    }

    func testFailedCreationDoesNotDeleteStoredKey() async throws {
        let keys = InMemoryKeyStore()
        let session = VaultSession(storage: RejectingSessionStorage(), keyStore: keys, auth: TestAuth())
        defer { session.lock() }
        do {
            try await session.createNewVault()
            XCTFail("Conflicting creation must fail")
        } catch { XCTAssertEqual(error as? VaultStorageError, .conflict) }
        XCTAssertTrue(try keys.keyExists(), "A failed write does not prove exclusive key ownership")
        XCTAssertFalse(session.isUnlocked)
        XCTAssertNil(session.currentPayload)
        XCTAssertEqual(session.lastError, VaultStorageError.conflict.errorDescription)
    }

    func testStaleSessionEditPreservesDiskAndPayloadUntilReload() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryKeyStore()
        let first = VaultSession(storage: try FileSystemVaultStorage(directory: directory), keyStore: keys, auth: TestAuth())
        let second = VaultSession(storage: try FileSystemVaultStorage(directory: directory), keyStore: keys, auth: TestAuth())
        defer { first.lock(); second.lock() }
        try await first.createNewVault()
        try await second.unlock()
        try await first.mutate { $0.items.append(VaultItem(title: "First writer")) }
        let committed = try Data(contentsOf: first.storageURL)
        let generation = second.sessionGeneration
        do {
            try await second.mutate { $0.items.append(VaultItem(title: "Stale writer")) }
            XCTFail("Stale writes must fail rather than lose another session's edit")
        } catch {
            XCTAssertEqual(error as? VaultStorageError, .conflict)
            XCTAssertEqual(second.lastError, VaultStorageError.conflict.errorDescription)
        }
        XCTAssertEqual(try Data(contentsOf: first.storageURL), committed)
        XCTAssertTrue(try XCTUnwrap(second.currentPayload).items.isEmpty)
        XCTAssertEqual(second.sessionGeneration, generation)
        second.lock()
        try await second.unlock()
        XCTAssertNil(second.lastError)
        XCTAssertEqual(second.currentPayload?.items.map(\.title), ["First writer"])
        try await second.mutate { $0.items.append(VaultItem(title: "After reload")) }
        second.lock()
        try await second.unlock()
        XCTAssertEqual(second.currentPayload?.items.map(\.title), ["First writer", "After reload"])
    }
}
