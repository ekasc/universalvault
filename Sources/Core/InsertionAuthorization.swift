import Foundation

public struct InsertionAuthorization: Sendable {
  public let field: VaultField
  public let requiresPresence: Bool
  private let itemID: UUID
  private let generation: UUID
  private let sensitivePolicy: Bool

  public init?(itemID: UUID, fieldID: UUID, payload: VaultPayload, generation: UUID) {
    guard let item = payload.items.first(where: { $0.id == itemID }),
      let field = item.fields.first(where: { $0.id == fieldID })
    else { return nil }
    self.itemID = itemID
    self.field = field
    self.generation = generation
    sensitivePolicy = payload.settings.requireAuthForSensitiveInsert
    requiresPresence =
      field.sensitivity == .critical
      || (field.sensitivity == .sensitive && sensitivePolicy)
  }

  public func isValid(in payload: VaultPayload?, generation: UUID) -> Bool {
    guard generation == self.generation, let payload,
      payload.settings.requireAuthForSensitiveInsert == sensitivePolicy,
      let item = payload.items.first(where: { $0.id == itemID }),
      let current = item.fields.first(where: { $0.id == field.id })
    else { return false }
    return current == field
  }
}
