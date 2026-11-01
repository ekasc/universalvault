import XCTest
@testable import VaultSecurity

private final class WriteOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var successes: [Data] = []
    private var errors: [any Error] = []

    func record(data: Data, operation: () throws -> Void) {
        do {
            try operation()
            lock.withLock { successes.append(data) }
        } catch {
            lock.withLock { errors.append(error) }
        }
    }

    func snapshot() -> ([Data], [any Error]) {
        lock.withLock { (successes, errors) }
    }
}

private struct LegacyStorage: VaultStorage {
    let url = URL(fileURLWithPath: "/unused-mock-vault")
    func read() throws -> Data? { nil }
    func write(_ data: Data) throws { XCTFail("Atomic writes must not fall back to unconditional writes") }
    func exists() -> Bool { false }
}

final class StorageConcurrencyTests: XCTestCase {
    private func race(expected: Data?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StorageConcurrency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try FileSystemVaultStorage(directory: directory)
        let second = try FileSystemVaultStorage(directory: directory)
        if let expected { try first.write(expected) }
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let outcomes = WriteOutcomes()
        for (storage, bytes) in [(first, Data("writer one".utf8)), (second, Data("writer two".utf8))] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                ready.signal()
                start.wait()
                outcomes.record(data: bytes) { try storage.write(bytes, expected: expected) }
            }
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        start.signal()
        start.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let (successes, errors) = outcomes.snapshot()
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first as? VaultStorageError, .conflict)
        XCTAssertEqual(try first.read(), successes.first)
        XCTAssertEqual(try second.read(), successes.first)
        let manager = FileManager.default
        for (url, permissions) in [(directory, 0o700), (first.url, 0o600), (first.url.appendingPathExtension("lock"), 0o600)] {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, permissions)
        }
        XCTAssertFalse(manager.fileExists(atPath: first.url.appendingPathExtension("tmp").path))
    }

    func testSimultaneousCreationHasExactlyOneWinner() throws {
        try race(expected: nil)
    }

    func testSimultaneousReplacementHasExactlyOneWinner() throws {
        try race(expected: Data("original bytes".utf8))
    }

    func testMissingAndChangedExpectationsPreserveDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StorageExpectations-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try FileSystemVaultStorage(directory: directory)
        let bytes = Data("encrypted bytes".utf8)
        XCTAssertThrowsError(try storage.write(bytes, expected: bytes)) {
            XCTAssertEqual($0 as? VaultStorageError, .conflict)
        }
        XCTAssertNil(try storage.read())
        try storage.write(bytes, expected: nil)
        for expected in [nil, Data("stale bytes".utf8)] as [Data?] {
            XCTAssertThrowsError(try storage.write(Data("replacement".utf8), expected: expected)) {
                XCTAssertEqual($0 as? VaultStorageError, .conflict)
            }
            XCTAssertEqual(try storage.read(), bytes)
        }
    }

    func testLegacyConformerFailsClosedForAtomicWrites() throws {
        let storage: any VaultStorage = LegacyStorage()
        XCTAssertThrowsError(try storage.write(Data(), expected: nil)) {
            XCTAssertEqual($0 as? VaultStorageError, .atomicWriteUnsupported)
        }
    }
}
