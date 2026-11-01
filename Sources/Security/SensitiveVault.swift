import Core
import CryptoKit
import Foundation

/// The second encryption layer for items the user marks sensitive.
///
/// The vault payload is already encrypted under the vault key, which the app can
/// read at launch. A sensitive item's fields are sealed a second time under the
/// sensitive key, which lives in the Keychain behind user presence. Without that
/// key the fields are ciphertext, so a locked item is not readable — not merely
/// hidden in the interface.
public enum SensitiveVault {
  /// The seal is bound to the schema, not to an item id, so duplicating or
  /// reordering an item keeps its sealed contents valid.
  public static let aad = Data("UniversalVault|item-seal|v1".utf8)

  public static func seal(fields: [VaultField], key: SymmetricKey) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let plaintext = try encoder.encode(fields)
    let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
    guard let combined = sealed.combined else { throw CryptoEnvelopeError.invalidData }
    return combined
  }

  public static func open(_ data: Data, key: SymmetricKey) throws -> [VaultField] {
    let box = try AES.GCM.SealedBox(combined: data)
    let plaintext: Data
    do {
      plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
    } catch {
      throw CryptoEnvelopeError.decryptionFailed
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([VaultField].self, from: plaintext)
  }
}
