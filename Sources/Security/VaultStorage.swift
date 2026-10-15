import Core
import Foundation

public protocol VaultStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func exists() -> Bool
    var url: URL { get }
}

public final class FileSystemVaultStorage: VaultStorage {
    public let url: URL

    public init(directory: URL? = nil) throws {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UniversalVault", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("vault.uv")
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func exists() -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
