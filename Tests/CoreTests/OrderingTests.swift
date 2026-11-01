import Core
import XCTest

final class OrderingTests: XCTestCase {
  func testImportedMaximumSortOrderCannotCrashCreation() {
    let item = VaultItem(title: "Imported", sortOrder: Int.max)
    XCTAssertEqual(VaultBrowser.nextItemSortOrder([item]), Int.max)
    let category = VaultCategory(name: "Imported", sortOrder: Int.max)
    XCTAssertEqual(VaultBrowser.nextSortOrder([category], parentID: nil), Int.max)
    var payload = VaultPayload(items: [item])
    _ = payload.addItem()
    XCTAssertEqual(payload.items.count, 2)
  }
  func testScopedItemMovePreservesUnrelatedPositionsAndValues() throws {
    let category = VaultCategory(name: "Category")
    let a = VaultItem(title: "A", categoryID: category.id, sortOrder: 0)
    let other = VaultItem(title: "Other", sortOrder: 1)
    let b = VaultItem(title: "B", categoryID: category.id, sortOrder: 2)
    var payload = VaultPayload(categories: [category], items: [a, other, b])
    try payload.moveItem(b.id, by: -1, in: .category(category.id))
    XCTAssertEqual(payload.items.map(\.title), ["B", "Other", "A"])
    XCTAssertEqual(payload.items.map(\.sortOrder), [0, 1, 2])
    XCTAssertNoThrow(try payload.validated())
  }

  func testUnknownAndDuplicateOrderingDoesNotMutateItems() {
    let item = VaultItem(title: "Item")
    var payload = VaultPayload(items: [item])
    XCTAssertThrowsError(try payload.reorderItems([item.id, item.id]))
    XCTAssertThrowsError(try payload.reorderItems([UUID()]))
    XCTAssertEqual(payload.items, [item])
  }

  func testFieldMovePreservesIdentityAndValue() {
    let a = VaultField(key: "a", label: "A", value: .text("one"))
    let b = VaultField(key: "b", label: "B", value: .text("two"))
    var item = VaultItem(title: "Item", fields: [a, b])
    item.moveField(b.id, by: -1)
    XCTAssertEqual(item.fields.map(\.id), [b.id, a.id])
    XCTAssertEqual(item.fields.map(\.value), [.text("two"), .text("one")])
    XCTAssertEqual(item.fields.map(\.sortOrder), [0, 1])
  }

  func testCollapseHidesOnlyDescendants() {
    let root = VaultCategory(name: "Root")
    let child = VaultCategory(name: "Child", parentID: root.id)
    let other = VaultCategory(name: "Other")
    let rows = VaultBrowser.categoryRows([root, child, other], collapsed: [root.id])
    XCTAssertEqual(Set(rows.map(\.id)), [root.id, other.id])
  }
}
