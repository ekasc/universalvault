import Core
import Foundation
import CryptoKit

public enum CryptoEnvelopeError: Error, LocalizedError {
    case unsupportedVersion
    case decryptionFailed
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "Unsupported vault format version."
        case .decryptionFailed: return "Vault decryption failed; data may be tampered."
        case .invalidData: return "Invalid vault data."
        }
    }
}

public struct VaultEnvelope: Codable {
    public static let currentFormatVersion = 1
    public let format: String
    public let formatVersion: Int
    public let keyID: String?
    public let sealedBox: String // base64 combined

    public init(formatVersion: Int = 1, keyID: String? = nil, sealedBox: String) {
        self.format = "universal-vault"
        self.formatVersion = formatVersion
        self.keyID = keyID
        self.sealedBox = sealedBox
    }
}

public enum VaultCrypto {
    public static let aad = Data("UniversalVault|format=v1".utf8)

    public static func encrypt(payload: VaultPayload, key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.aad)
        guard let combined = sealed.combined else { throw CryptoEnvelopeError.invalidData }
        let env = VaultEnvelope(formatVersion: 1, keyID: nil, sealedBox: combined.base64EncodedString())
        let envEncoder = JSONEncoder()
        envEncoder.outputFormatting = [.sortedKeys]
        return try envEncoder.encode(env)
    }

    public static func decrypt(_ data: Data, key: SymmetricKey) throws -> VaultPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let env: VaultEnvelope
        do { env = try decoder.decode(VaultEnvelope.self, from: data) } catch { throw CryptoEnvelopeError.invalidData }
        guard env.format == "universal-vault", env.formatVersion == VaultEnvelope.currentFormatVersion else {
            throw CryptoEnvelopeError.unsupportedVersion
        }
        guard let boxData = Data(base64Encoded: env.sealedBox) else { throw CryptoEnvelopeError.invalidData }
        let box = try AES.GCM.SealedBox(combined: boxData)
        do {
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.aad)
            return try decoder.decode(VaultPayload.self, from: plaintext)
        } catch {
            throw CryptoEnvelopeError.decryptionFailed
        }
    }
}
