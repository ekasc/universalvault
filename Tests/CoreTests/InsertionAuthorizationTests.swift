import Core
import XCTest

final class InsertionAuthorizationTests: XCTestCase {
  private func fixture(_ sensitivity: SensitivityLevel = .normal) -> VaultPayload {
    VaultPayload(items: [
      VaultItem(
        title: "Item",
        fields: [
          VaultField(
            key: "value", label: "Value", value: .text("synthetic"), sensitivity: sensitivity)
        ])
    ])
  }

  func testChangedOrDeletedFieldInvalidatesAuthorization() throws {
    var payload = fixture()
    let generation = UUID()
    let authorization = try XCTUnwrap(
      InsertionAuthorization(
        itemID: payload.items[0].id,
        fieldID: payload.items[0].fields[0].id, payload: payload, generation: generation))
    XCTAssertTrue(authorization.isValid(in: payload, generation: generation))
    payload.items[0].fields[0].sensitivity = .critical
    XCTAssertFalse(authorization.isValid(in: payload, generation: generation))
    payload.items[0].fields.removeAll()
    XCTAssertFalse(authorization.isValid(in: payload, generation: generation))
  }

  func testLockReplacementPolicyAndValueChangesInvalidateAuthorization() throws {
    let payload = fixture()
    let generation = UUID()
    let authorization = try XCTUnwrap(
      InsertionAuthorization(
        itemID: payload.items[0].id,
        fieldID: payload.items[0].fields[0].id, payload: payload, generation: generation))
    XCTAssertFalse(authorization.isValid(in: nil, generation: generation))
    XCTAssertFalse(authorization.isValid(in: payload, generation: UUID()))
    var changed = payload
    changed.items[0].fields[0].value = .text("changed")
    XCTAssertFalse(authorization.isValid(in: changed, generation: generation))
    changed = payload
    changed.settings.requireAuthForSensitiveInsert.toggle()
    XCTAssertFalse(authorization.isValid(in: changed, generation: generation))
  }

  func testCriticalAlwaysRequiresPresenceAndSensitiveHonorsPolicy() throws {
    for sensitivity in SensitivityLevel.allCases {
      for policy in [false, true] {
        var payload = fixture(sensitivity)
        payload.settings.requireAuthForSensitiveInsert = policy
        let authorization = try XCTUnwrap(
          InsertionAuthorization(
            itemID: payload.items[0].id,
            fieldID: payload.items[0].fields[0].id, payload: payload, generation: UUID()))
        XCTAssertEqual(
          authorization.requiresPresence,
          sensitivity == .critical || (sensitivity == .sensitive && policy))
      }
    }
  }
}
