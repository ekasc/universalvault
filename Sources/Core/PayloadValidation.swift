import Foundation

public enum PayloadValidationError: Error, LocalizedError, Equatable {
  case unsupportedSchema
  case duplicateIdentity
  case invalidReference
  case invalidField
  case invalidName

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema:
      return
        "This vault uses an unsupported data version. Open it with a compatible version of UniversalVault."
    case .duplicateIdentity:
      return "The vault contains duplicate identities. The existing vault has not been replaced."
    case .invalidReference: return "The vault contains an invalid category or profile reference."
    case .invalidField:
      return "A field has an invalid value for its type. No values were discarded."
    case .invalidName: return "Vault items, fields, categories, and profiles need nonempty names."
    }
  }
}

extension VaultPayload {
  public func validated() throws -> VaultPayload {
    guard schemaVersion == 1 else { throw PayloadValidationError.unsupportedSchema }
    func unique(_ ids: [UUID]) throws -> Set<UUID> {
      let set = Set(ids)
      guard set.count == ids.count else { throw PayloadValidationError.duplicateIdentity }
      return set
    }
    _ = try unique(items.map(\.id))
    _ = try unique(items.flatMap { $0.fields.map(\.id) })
    let categoryIDs = try unique(categories.map(\.id))
    let profileIDs = try unique(profiles.map(\.id))
    func named(_ name: String) -> Bool {
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard categories.allSatisfy({ named($0.name) }), profiles.allSatisfy({ named($0.name) }) else {
      throw PayloadValidationError.invalidName
    }
    guard categories.allSatisfy({ $0.parentID.map { categoryIDs.contains($0) } ?? true }) else {
      throw PayloadValidationError.invalidReference
    }
    var result = self
    for index in result.items.indices {
      let item = result.items[index]
      guard named(item.title), item.fields.allSatisfy({ named($0.key) && named($0.label) }) else {
        throw PayloadValidationError.invalidName
      }
      guard item.categoryID.map({ categoryIDs.contains($0) }) ?? true,
        item.profileID.map({ profileIDs.contains($0) }) ?? true
      else {
        throw PayloadValidationError.invalidReference
      }
      for fieldIndex in item.fields.indices {
        result.items[index].fields[fieldIndex] = try item.fields[fieldIndex].validated()
      }
    }
    result.settings.autoLockMinutes = AutoLock.clampedMinutes(settings.autoLockMinutes)
    return result
  }
}

extension VaultField {
  fileprivate func validated() throws -> VaultField {
    var field = self
    if case .text(let text) = field.value {
      switch type {
      case .text: break
      case .multiline: field.value = .multiline(text)
      case .email: field.value = .email(text)
      case .url: field.value = .url(text)
      case .phone: field.value = .phone(text)
      case .secret: field.value = .secret(text)
      case .custom: field.value = .custom(text)
      case .number where text.isEmpty: field.value = .number(nil)
      case .date where text.isEmpty: field.value = .date(nil)
      case .boolean where text.isEmpty: field.value = .boolean(false)
      default: throw PayloadValidationError.invalidField
      }
    }
    switch (type, field.value) {
    case (.text, .text), (.multiline, .multiline), (.email, .email), (.url, .url),
      (.phone, .phone), (.secret, .secret), (.boolean, .boolean), (.custom, .custom):
      break
    case (.number, .number(let number)):
      guard number?.isFinite ?? true else { throw PayloadValidationError.invalidField }
    case (.date, .date(let date)):
      guard date?.timeIntervalSince1970.isFinite ?? true else {
        throw PayloadValidationError.invalidField
      }
    default: throw PayloadValidationError.invalidField
    }
    if type == .secret { field.sensitivity = max(.sensitive, sensitivity) }
    return field
  }
}
