import XCTest
import Darwin
@testable import VaultSecurity

private enum PermissionFailure: Error { case denied }

private final class PermissionFailingFileManager: FileManager, @unchecked Sendable {
    let rejectedName: String

    init(rejectedName: String) {
        self.rejectedName = rejectedName
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if URL(fileURLWithPath: path).lastPathComponent == rejectedName { throw PermissionFailure.denied }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

final class StorageTests: XCTestCase {
    func testContendedLockRejectsWithoutChangingData() throws {
        try withDirectory { directory in
            let storage = try FileSystemVaultStorage(directory: directory)
            let original = Data("original".utf8)
            try storage.write(original)
            let descriptor = open(storage.url.appendingPathExtension("lock").path, O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { flock(descriptor, LOCK_UN); close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try storage.write(Data("must not replace".utf8), expected: original)) {
                XCTAssertEqual($0 as? VaultStorageError, .conflict)
            }
            XCTAssertEqual(try storage.read(), original)
        }
    }
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UniversalVaultStorage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testPermissionCheckCannotFailAfterCommit() throws {
        try withDirectory { directory in
            let manager = PermissionFailingFileManager(rejectedName: "vault.uv")
            let storage = try FileSystemVaultStorage(directory: directory)
            let data = Data("synthetic encrypted bytes".utf8)
            XCTAssertNoThrow(try storage.write(data, fileManager: manager))
            XCTAssertEqual(try storage.read(), data)
            let changed = Data("replacement encrypted bytes".utf8)
            XCTAssertNoThrow(try storage.write(changed, fileManager: manager))
            XCTAssertEqual(try storage.read(), changed)
        }
    }

    func testPrecommitPermissionFailurePreservesOriginalAndRemovesTemporaryFile() throws {
        try withDirectory { directory in
            let original = try FileSystemVaultStorage(directory: directory)
            let data = Data("original encrypted bytes".utf8)
            try original.write(data)
            let manager = PermissionFailingFileManager(rejectedName: "vault.uv.tmp")
            XCTAssertThrowsError(try original.write(Data("must not commit".utf8), fileManager: manager))
            XCTAssertEqual(try original.read(), data)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["vault.uv", "vault.uv.lock"])
        }
    }

    func testReplacementUsesPrivateNewPermissions() throws {
        try withDirectory { directory in
            let storage = try FileSystemVaultStorage(directory: directory)
            try storage.write(Data("first".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storage.url.path)
            try storage.write(Data("second".utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: storage.url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try storage.read(), Data("second".utf8))
        }
    }
}
