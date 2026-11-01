import Core
import Foundation
import Darwin

public protocol VaultStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    /// Atomically writes only if current bytes equal `expected`; nil requires no vault.
    func write(_ data: Data, expected: Data?) throws
    func preserveForRecovery(_ expected: Data) throws -> URL
    func exists() -> Bool
    var url: URL { get }
}

public enum VaultStorageError: Error, LocalizedError, Equatable {
    case conflict
    case atomicWriteUnsupported
    case applicationSupportUnavailable

    public var errorDescription: String? {
        switch self {
        case .conflict:
            return "The vault changed in another session. Lock and unlock to reload it before saving again."
        case .atomicWriteUnsupported:
            return "This vault storage does not support atomic updates. Use storage with atomic update support."
        case .applicationSupportUnavailable:
            return "macOS did not provide an Application Support directory for the vault."
        }
    }
}

public extension VaultStorage {
    func write(_ data: Data, expected: Data?) throws {
        throw VaultStorageError.atomicWriteUnsupported
    }
    func preserveForRecovery(_ expected: Data) throws -> URL {
        throw VaultStorageError.atomicWriteUnsupported
    }
}

public final class FileSystemVaultStorage: VaultStorage {
    public let url: URL

    public init(directory: URL? = nil) throws {
        let fileManager = FileManager.default
        let resolvedBase: URL
        if let directory {
            resolvedBase = directory
        } else {
            guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw VaultStorageError.applicationSupportUnavailable
            }
            resolvedBase = support.appendingPathComponent("UniversalVault", isDirectory: true)
        }
        let base = resolvedBase
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        self.url = base.appendingPathComponent("vault.uv")
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data) throws {
        try write(data, fileManager: .default)
    }

    public func write(_ data: Data, expected: Data?) throws {
        try withWriteLock {
            guard try read() == expected else { throw VaultStorageError.conflict }
            try commit(data, fileManager: .default)
        }
    }

    public func preserveForRecovery(_ expected: Data) throws -> URL {
        let archive = url.deletingLastPathComponent().appendingPathComponent("vault-recovery-\(UUID()).uv")
        try withWriteLock {
            guard try read() == expected else { throw VaultStorageError.conflict }
            try expected.write(to: archive, options: .withoutOverwriting)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
            } catch {
                try? FileManager.default.removeItem(at: archive)
                throw error
            }
        }
        return archive
    }

    func write(_ data: Data, fileManager: FileManager) throws {
        try withWriteLock { try commit(data, fileManager: fileManager) }
    }

    private func withWriteLock(_ body: () throws -> Void) throws {
        // Keep this inode stable across replacements and across storage instances.
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { throw VaultStorageError.conflict }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        try body()
    }

    private func commit(_ data: Data, fileManager: FileManager) throws {
        let tmp = url.appendingPathExtension("tmp")
        defer { try? fileManager.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        // Permission checks precede commit. A successful replacement must not
        // inherit old permissions or be followed by another throwing operation.
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: tmp, to: url)
        }
    }

    public func exists() -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
