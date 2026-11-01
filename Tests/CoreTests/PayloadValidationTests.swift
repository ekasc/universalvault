import XCTest

@testable import Core

final class PayloadValidationTests: XCTestCase {
  func testNormalSecretIsRaisedAtBoundary() throws {
    let field = VaultField(
      key: "password", label: "Password", type: .secret, value: .secret("synthetic"))
    let payload = VaultPayload(items: [VaultItem(title: "Imported", fields: [field])])
    XCTAssertEqual(try payload.validated().items[0].fields[0].sensitivity, .sensitive)
  }

  func testDuplicateIdentitiesAreRejected() {
    let item = VaultItem(title: "Duplicate")
    XCTAssertThrowsError(try VaultPayload(items: [item, item]).validated())
    let field = VaultField(key: "field", label: "Field")
    XCTAssertThrowsError(
      try VaultPayload(items: [VaultItem(title: "Item", fields: [field, field])]).validated())
    let category = VaultCategory(name: "Category")
    XCTAssertThrowsError(try VaultPayload(categories: [category, category]).validated())
  }

  func testUnsupportedSchemaAndDanglingReferencesAreRejected() {
    XCTAssertThrowsError(try VaultPayload(schemaVersion: 2).validated())
    XCTAssertThrowsError(
      try VaultPayload(items: [VaultItem(title: "Item", categoryID: UUID())]).validated())
  }

  func testLegacyEmptyTypedFieldsBecomeEmptyTypedValues() throws {
    let payload = VaultPayload(items: [
      VaultItem(
        title: "Legacy",
        fields: [
          VaultField(key: "date", label: "Date", type: .date),
          VaultField(key: "number", label: "Number", type: .number),
          VaultField(key: "email", label: "Email", type: .email),
        ])
    ])
    let fields = try payload.validated().items[0].fields
    XCTAssertEqual(fields[0].value, .date(nil))
    XCTAssertEqual(fields[0].insertionText, "")
    XCTAssertEqual(fields[1].value, .number(nil))
    XCTAssertEqual(fields[2].value, .email(""))
  }

  func testMismatchedValuesAreNotSilentlyDiscarded() {
    let field = VaultField(key: "date", label: "Date", type: .date, value: .text("not a date"))
    XCTAssertThrowsError(
      try VaultPayload(items: [VaultItem(title: "Item", fields: [field])]).validated())
  }

  func testEveryTemplateValidatesWithoutInventingDates() throws {
    for template in Templates.all() {
      let item = try VaultPayload(items: [template.build()]).validated().items[0]
      for field in item.fields where field.type == .date {
        XCTAssertEqual(field.insertionText, "", template.name)
      }
    }
  }
}
