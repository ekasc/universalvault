import XCTest
import Core

final class BrowserTests: XCTestCase {
    private func category(_ name: String, order: Int, parent: UUID? = nil) -> VaultCategory {
        VaultCategory(name: name, parentID: parent, sortOrder: order)
    }

    private func item(_ title: String, order: Int, category: UUID? = nil, profile: UUID? = nil, fields: [VaultField] = [], tags: [String] = []) -> VaultItem {
        VaultItem(title: title, categoryID: category, profileID: profile, tags: tags, fields: fields, sortOrder: order)
    }

    // MARK: - VaultCategory ordering

    func testCategoriesOrderBySortOrderThenName() {
        let rows = VaultBrowser.categoryRows([category("Zed", order: 1), category("Ann", order: 0), category("Bea", order: 1)])
        XCTAssertEqual(rows.map(\.category.name), ["Ann", "Bea", "Zed"])
    }

    func testCategoriesNestDepthFirst() {
        let parent = category("Parent", order: 0)
        let child = category("Child", order: 0, parent: parent.id)
        let sibling = category("Sibling", order: 1)
        let rows = VaultBrowser.categoryRows([sibling, child, parent])
        XCTAssertEqual(rows.map(\.category.name), ["Parent", "Child", "Sibling"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
    }

    func testCategoryWithMissingParentBecomesARoot() {
        let orphan = category("Orphan", order: 0, parent: UUID())
        let rows = VaultBrowser.categoryRows([orphan])
        XCTAssertEqual(rows.map(\.category.name), ["Orphan"])
        XCTAssertEqual(rows.first?.depth, 0)
    }

    func testCyclicCategoriesTerminateAndStayVisible() {
        let a = UUID()
        let b = UUID()
        let one = VaultCategory(id: a, name: "A", parentID: b, sortOrder: 0)
        let two = VaultCategory(id: b, name: "B", parentID: a, sortOrder: 0)
        let rows = VaultBrowser.categoryRows([one, two])
        XCTAssertEqual(rows.count, 2, "a cycle must not hide a category or loop forever")
        XCTAssertEqual(Set(rows.map(\.category.name)), ["A", "B"])
        XCTAssertEqual(rows.map(\.depth), [0, 0])
    }

    func testSelfParentedCategoryIsARoot() {
        let id = UUID()
        let rows = VaultBrowser.categoryRows([VaultCategory(id: id, name: "Self", parentID: id, sortOrder: 0)])
        XCTAssertEqual(rows.map(\.depth), [0])
    }

    // MARK: - Item filtering

    func testSelectionFiltersItems() {
        let cat = UUID()
        let prof = UUID()
        let items = [
            item("A", order: 0, category: cat),
            item("B", order: 1, profile: prof),
            item("C", order: 2),
        ]
        XCTAssertEqual(VaultBrowser.items(items, selection: .allItems).map(\.title), ["A", "B", "C"])
        XCTAssertEqual(VaultBrowser.items(items, selection: .category(cat)).map(\.title), ["A"])
        XCTAssertEqual(VaultBrowser.items(items, selection: .profile(prof)).map(\.title), ["B"])
        XCTAssertEqual(VaultBrowser.items(items, selection: .category(UUID())).map(\.title), [])
    }

    func testItemsOrderBySortOrderThenTitle() {
        let items = [item("Zed", order: 1), item("Ann", order: 0), item("Bea", order: 1)]
        XCTAssertEqual(VaultBrowser.items(items, selection: .allItems).map(\.title), ["Ann", "Bea", "Zed"])
    }

    func testSearchMatchesTitleTagAndFieldMetadata() {
        let withField = VaultField(key: "iban", label: "Bank Account", type: .text, aliases: ["Account Number"])
        let items = [
            item("Passport", order: 0),
            item("Bank", order: 1, fields: [withField], tags: ["finance"]),
        ]
        XCTAssertEqual(VaultBrowser.items(items, selection: .allItems, search: "pass").map(\.title), ["Passport"])
        XCTAssertEqual(VaultBrowser.items(items, selection: .allItems, search: "bank").map(\.title), ["Bank"])
        XCTAssertEqual(VaultBrowser.items(items, selection: .allItems, search: "account").map(\.title), ["Bank"])
        XCTAssertEqual(VaultBrowser.items(items, selection: .allItems, search: "finance").map(\.title), ["Bank"])
        XCTAssertEqual(VaultBrowser.items(items, selection: .allItems, search: "nothing"), [])
    }

    func testSearchAppliesWithinTheSelectedScope() {
        let cat = UUID()
        let items = [
            item("Bank", order: 0, category: cat),
            item("Bank", order: 1),
        ]
        XCTAssertEqual(VaultBrowser.items(items, selection: .category(cat), search: "bank").count, 1)
    }

    func testBlankSearchMatchesEverything() {
        let items = [item("A", order: 0), item("B", order: 1)]
        XCTAssertEqual(VaultBrowser.items(items, selection: .allItems, search: "   ").count, 2)
    }

    // MARK: - Counts and ordering helpers

    func testItemCountsAggregateByCategoryAndProfile() {
        let cat = UUID()
        let prof = UUID()
        let items = [
            item("A", order: 0, category: cat, profile: prof),
            item("B", order: 1, category: cat),
            item("C", order: 2),
        ]
        let counts = VaultBrowser.itemCounts(items)
        XCTAssertEqual(counts.categories[cat], 2)
        XCTAssertEqual(counts.profiles[prof], 1)
        XCTAssertNil(counts.categories[UUID()])
    }

    func testNextSortOrderContinuesWithinTheSameParent() {
        let root = category("Root", order: 0)
        let child = category("Child", order: 0, parent: root.id)
        let categories = [root, child]
        XCTAssertEqual(VaultBrowser.nextSortOrder(categories, parentID: nil), 1)
        XCTAssertEqual(VaultBrowser.nextSortOrder(categories, parentID: root.id), 1)
        XCTAssertEqual(VaultBrowser.nextSortOrder(categories, parentID: UUID()), 0)
    }

    func testNextItemSortOrderStartsAtZeroWhenEmpty() {
        XCTAssertEqual(VaultBrowser.nextItemSortOrder([]), 0)
        XCTAssertEqual(VaultBrowser.nextItemSortOrder([item("A", order: 0), item("B", order: 4)]), 5)
    }

    // MARK: - Date insert format

    func testDateFormatDefaultsToISODate() {
        XCTAssertEqual(DateInsertFormat.resolved(nil), "yyyy-MM-dd")
        XCTAssertEqual(DateInsertFormat.resolved(""), "yyyy-MM-dd")
        XCTAssertEqual(DateInsertFormat.resolved("dd/MM/yyyy"), "dd/MM/yyyy")
        XCTAssertTrue(DateInsertFormat.isPreset("yyyy-MM-dd"))
        XCTAssertTrue(DateInsertFormat.isPreset("locale-short"))
        XCTAssertFalse(DateInsertFormat.isPreset("yyyy.MM.dd"))
    }
}
