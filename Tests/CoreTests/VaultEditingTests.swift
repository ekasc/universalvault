import XCTest
import Core

final class VaultEditingTests: XCTestCase {

    // MARK: - Items

    func testAddedItemGetsTheNextSortOrderAndCanBeScoped() throws {
        var payload = VaultPayload()
        let category = try payload.addCategory(name: "Identity")
        let first = payload.addItem(title: "One")
        let second = payload.addItem(title: "Two", categoryID: category)

        XCTAssertEqual(payload.items.map(\.sortOrder), [0, 1])
        XCTAssertEqual(payload.items.first(where: { $0.id == first })?.categoryID, nil)
        XCTAssertEqual(payload.items.first(where: { $0.id == second })?.categoryID, category)
    }

    func testDuplicatingAnItemCopiesFieldsWithNewIdentities() throws {
        var payload = VaultPayload()
        let original = payload.addItem(title: "Passport")
        payload.updateItem(original) { item in
            item.fields = [VaultField(key: "number", label: "Number", type: .text, value: .text("X"))]
        }
        let copyID = try XCTUnwrap(payload.duplicateItem(original))
        let copy = try XCTUnwrap(payload.items.first(where: { $0.id == copyID }))
        let source = try XCTUnwrap(payload.items.first(where: { $0.id == original }))

        XCTAssertEqual(copy.title, "Passport copy")
        XCTAssertEqual(copy.fields.count, 1)
        XCTAssertNotEqual(copy.fields[0].id, source.fields[0].id, "shared field ids would make edits ambiguous")
        XCTAssertEqual(copy.fields[0].value, source.fields[0].value)
    }

    func testUpdatingAnItemStampsUpdatedAt() throws {
        var payload = VaultPayload()
        let id = payload.addItem(title: "One")
        let before = try XCTUnwrap(payload.items.first?.updatedAt)
        payload.updateItem(id) { $0.title = "Renamed" }
        XCTAssertEqual(payload.items.first?.title, "Renamed")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(payload.items.first?.updatedAt), before)
    }

    func testUpdatingAMissingItemIsANoOp() {
        var payload = VaultPayload()
        payload.updateItem(UUID()) { $0.title = "Ghost" }
        XCTAssertTrue(payload.items.isEmpty)
    }

    // MARK: - Categories

    func testEmptyCategoryNameIsRejected() throws {
        var payload = VaultPayload()
        XCTAssertThrowsError(try payload.addCategory(name: "   ")) { error in
            XCTAssertEqual(error as? VaultEditError, .emptyName)
        }
        XCTAssertTrue(payload.categories.isEmpty)
    }

    func testCategoryNamesAreTrimmed() throws {
        var payload = VaultPayload()
        try payload.addCategory(name: "  Identity  ")
        XCTAssertEqual(payload.categories.first?.name, "Identity")
    }

    func testUnknownParentIsDropped() throws {
        var payload = VaultPayload()
        let id = try payload.addCategory(name: "Child", parentID: UUID())
        XCTAssertNil(payload.categories.first(where: { $0.id == id })?.parentID,
                     "a stale parent id would hide the category under a phantom branch")
    }

    func testSiblingSortOrderIncrementsPerParent() throws {
        var payload = VaultPayload()
        let root = try payload.addCategory(name: "Root")
        let child = try payload.addCategory(name: "Child", parentID: root)
        try payload.addCategory(name: "Second child", parentID: root)
        try payload.addCategory(name: "Second root")

        let childRow = payload.categories.first { $0.id == child }
        let secondChild = payload.categories.first { $0.name == "Second child" }
        let secondRoot = payload.categories.first { $0.name == "Second root" }
        XCTAssertEqual(childRow?.sortOrder, 0)
        XCTAssertEqual(secondChild?.sortOrder, 1)
        XCTAssertEqual(secondRoot?.sortOrder, 1, "sort order counts within the same parent only")
    }

    func testDeletingACategoryPromotesChildrenAndUncategorizesItems() throws {
        var payload = VaultPayload()
        let parent = try payload.addCategory(name: "Parent")
        let middle = try payload.addCategory(name: "Middle", parentID: parent)
        let leaf = try payload.addCategory(name: "Leaf", parentID: middle)
        let item = payload.addItem(title: "Scoped", categoryID: middle)

        payload.deleteCategory(middle)

        XCTAssertFalse(payload.categories.contains { $0.id == middle })
        XCTAssertEqual(payload.categories.first { $0.id == leaf }?.parentID, parent,
                       "children move up rather than being deleted")
        XCTAssertNil(payload.items.first { $0.id == item }?.categoryID,
                     "items must survive their category")
        XCTAssertEqual(payload.items.count, 1)
    }

    func testDeletingAnUnusedCategoryDoesNothingElse() throws {
        var payload = VaultPayload()
        let keep = try payload.addCategory(name: "Keep")
        let drop = try payload.addCategory(name: "Drop")
        let item = payload.addItem(title: "Scoped", categoryID: keep)

        payload.deleteCategory(drop)

        XCTAssertEqual(payload.categories.map(\.name), ["Keep"])
        XCTAssertEqual(payload.items.first { $0.id == item }?.categoryID, keep)
    }

    func testRenamingAMissingCategoryIsANoOp() throws {
        var payload = VaultPayload()
        try payload.renameCategory(UUID(), to: "Nothing")
        XCTAssertTrue(payload.categories.isEmpty)
    }

    // MARK: - Profiles

    func testProfilesAppendInOrderAndRename() throws {
        var payload = VaultPayload()
        let first = try payload.addProfile(name: "Work")
        try payload.addProfile(name: "Personal")
        XCTAssertEqual(payload.profiles.map(\.sortOrder), [0, 1])
        try payload.renameProfile(first, to: "Office")
        XCTAssertEqual(payload.profiles.first?.name, "Office")
    }

    func testDeletingAProfileUnassignsItemsWithoutDeletingThem() throws {
        var payload = VaultPayload()
        let profile = try payload.addProfile(name: "Work")
        let item = payload.addItem(title: "Email", profileID: profile)
        payload.deleteProfile(profile)

        XCTAssertTrue(payload.profiles.isEmpty)
        XCTAssertEqual(payload.items.count, 1)
        XCTAssertNil(payload.items.first { $0.id == item }?.profileID)
    }

    func testProfileRejectsEmptyName() {
        var payload = VaultPayload()
        XCTAssertThrowsError(try payload.addProfile(name: "\n"))
        XCTAssertTrue(payload.profiles.isEmpty)
    }

    // MARK: - Sanitizing a per-keystroke editor value

    func testClearedTitleFallsBackToThePersistedOne() {
        let saved = VaultItem(title: "Passport")
        var edited = saved
        edited.title = "   "
        let clean = edited.sanitized(previous: saved, categoryIDs: [], profileIDs: [])
        XCTAssertEqual(clean.title, "Passport", "a cleared title must not block the rest of the form from saving")
    }

    func testClearedTitleWithNothingPersistedGetsAPlaceholder() {
        var edited = VaultItem(title: "")
        edited.title = ""
        XCTAssertEqual(edited.sanitized(previous: nil, categoryIDs: [], profileIDs: []).title, "Untitled")
    }

    func testOtherEditsSurviveAClearedTitle() {
        var saved = VaultItem(title: "Passport", fields: [VaultField(key: "number", label: "Number", type: .text)])
        saved.fields[0].value = .text("old")
        var edited = saved
        edited.title = ""
        edited.fields[0].value = .text("new")

        let clean = edited.sanitized(previous: saved, categoryIDs: [], profileIDs: [])
        XCTAssertEqual(clean.title, "Passport")
        XCTAssertEqual(clean.fields[0].value, .text("new"), "the field edit is the thing the user typed")
    }

    func testClearedFieldLabelAndKeyFallBackToThePersistedValues() {
        var saved = VaultItem(title: "T", fields: [VaultField(key: "iban", label: "IBAN", type: .text)])
        saved.fields[0].value = .text("x")
        var edited = saved
        edited.fields[0].key = ""
        edited.fields[0].label = ""

        let clean = edited.sanitized(previous: saved, categoryIDs: [], profileIDs: [])
        XCTAssertEqual(clean.fields[0].key, "iban")
        XCTAssertEqual(clean.fields[0].label, "IBAN")
        XCTAssertEqual(clean.fields[0].value, .text("x"))
    }

    func testClearedBrandNewFieldGetsGeneratedNames() {
        var edited = VaultItem(title: "T", fields: [VaultField(key: "", label: "", type: .text)])
        edited.fields[0].key = ""
        edited.fields[0].label = ""

        let clean = edited.sanitized(previous: nil, categoryIDs: [], profileIDs: [])
        XCTAssertFalse(clean.fields[0].key.isEmpty)
        XCTAssertFalse(clean.fields[0].label.isEmpty)
    }

    func testDeletedCategoryAndProfileAreNotWrittenBack() {
        let gone = UUID()
        let kept = UUID()
        var edited = VaultItem(title: "T", categoryID: gone, profileID: gone)
        edited.categoryID = gone
        edited.profileID = gone

        let clean = edited.sanitized(previous: nil, categoryIDs: [kept], profileIDs: [kept])
        XCTAssertNil(clean.categoryID, "a category deleted while the editor was open must not come back")
        XCTAssertNil(clean.profileID)

        var survivor = VaultItem(title: "T")
        survivor.categoryID = kept
        survivor.profileID = kept
        let keptClean = survivor.sanitized(previous: nil, categoryIDs: [kept], profileIDs: [kept])
        XCTAssertEqual(keptClean.categoryID, kept)
        XCTAssertEqual(keptClean.profileID, kept)
    }

    func testContentComparisonIgnoresTheSaveStamp() {
        var a = VaultItem(title: "T")
        var b = a
        b.updatedAt = Date().addingTimeInterval(60)
        XCTAssertTrue(a.hasSameContent(as: b), "every save stamps updatedAt; comparing it would report false conflicts")

        b.title = "Changed elsewhere"
        XCTAssertFalse(a.hasSameContent(as: b))
        a.title = "Changed elsewhere"
        XCTAssertTrue(a.hasSameContent(as: b))
    }

    func testValidationSummaryNamesAFieldByItsKeyWhenTheLabelIsCleared() {
        var item = VaultItem(title: "T", fields: [VaultField(key: "iban", label: "", type: .text)])
        item.fields[0].label = ""
        let summary = item.validationSummary
        XCTAssertTrue(summary.contains("iban"), "got: \(summary)")
        XCTAssertFalse(summary.contains("A field"))
    }

    func testEditorDoesNotOverwriteAnImportedItem() throws {
        let saved = VaultItem(title: "Before import")
        var imported = saved
        imported.title = "Imported"
        let payload = VaultPayload(items: [imported])
        var draft = saved
        draft.tags = ["typed after import"]

        XCTAssertThrowsError(try payload.itemForSaving(draft, replacing: saved)) { error in
            XCTAssertEqual(error as? VaultEditError, .itemChanged)
        }
        XCTAssertEqual(payload.items[0], imported)
    }

    func testEditorRejectsADeletedItem() {
        let saved = VaultItem(title: "Deleted")
        XCTAssertThrowsError(try VaultPayload().itemForSaving(saved, replacing: saved)) { error in
            XCTAssertEqual(error as? VaultEditError, .itemMissing)
        }
    }

    func testEditorPreservesEditsAfterCategoryAndProfileDeletion() throws {
        let category = VaultCategory(name: "Identity")
        let profile = Profile(name: "Work")
        let saved = VaultItem(title: "Passport", categoryID: category.id, profileID: profile.id)
        var payload = VaultPayload(profiles: [profile], categories: [category], items: [saved])
        payload.deleteCategory(category.id)
        payload.deleteProfile(profile.id)
        var draft = saved
        draft.title = "Updated passport"

        let clean = try XCTUnwrap(payload.itemForSaving(draft, replacing: saved))
        XCTAssertEqual(clean.title, draft.title)
        XCTAssertNil(clean.categoryID)
        XCTAssertNil(clean.profileID)
    }

    func testQueuedRevertIsComparedToTheLatestSave() throws {
        let original = VaultItem(title: "Original")
        var payload = VaultPayload(items: [original])
        var firstDraft = original
        firstDraft.title = "Intermediate"
        let firstSave = try XCTUnwrap(payload.itemForSaving(firstDraft, replacing: original))
        payload.updateItem(original.id) { $0 = firstSave }

        let reverted = try XCTUnwrap(payload.itemForSaving(original, replacing: firstSave))
        XCTAssertEqual(reverted.title, "Original")
    }

    func testClearedTitleUsesTheLatestSaveAsFallback() throws {
        let original = VaultItem(title: "Original")
        var payload = VaultPayload(items: [original])
        var firstDraft = original
        firstDraft.title = "Renamed"
        let firstSave = try XCTUnwrap(payload.itemForSaving(firstDraft, replacing: original))
        payload.updateItem(original.id) { $0 = firstSave }
        var secondDraft = firstDraft
        secondDraft.title = ""
        secondDraft.tags = ["still saved"]

        let clean = try XCTUnwrap(payload.itemForSaving(secondDraft, replacing: firstSave))
        XCTAssertEqual(clean.title, "Renamed")
        XCTAssertEqual(clean.tags, ["still saved"])
    }

    func testUnchangedEditorDoesNotRequestAWrite() throws {
        let item = VaultItem(title: "Unchanged")
        let payload = VaultPayload(items: [item])
        XCTAssertNil(try payload.itemForSaving(item, replacing: item))
    }

    func testTextTypeChangesPreserveTheValue() throws {
        let field = VaultField(key: "value", label: "Value", value: .text("Café 日本語"))
        let multiline = try field.changingType(to: .multiline)
        XCTAssertEqual(multiline.value, .multiline("Café 日本語"))
        XCTAssertEqual(try multiline.changingType(to: .email).value, .email("Café 日本語"))
    }

    func testSecretTypeChangePreservesValueAndRaisesSensitivity() throws {
        let field = VaultField(key: "value", label: "Value", value: .text("Synthetic secret"))
        let secret = try field.changingType(to: .secret)
        XCTAssertEqual(secret.value, .secret("Synthetic secret"))
        XCTAssertEqual(secret.sensitivity, .sensitive)
        var critical = field
        critical.sensitivity = .critical
        XCTAssertEqual(try critical.changingType(to: .secret).sensitivity, .critical)
    }

    func testSavingCannotDowngradeASecretToNormal() {
        let item = VaultItem(title: "T", fields: [VaultField(key: "s", label: "Secret", type: .secret)])
        let clean = item.sanitized(previous: item, categoryIDs: [], profileIDs: [])
        XCTAssertEqual(clean.fields[0].sensitivity, .sensitive)
    }

    func testIncompatibleTypeChangeRejectsInsteadOfDiscardingValue() {
        let field = VaultField(key: "value", label: "Value", value: .text("Not a number"))
        for type in [FieldType.number, .date, .boolean] {
            XCTAssertThrowsError(try field.changingType(to: type)) { error in
                XCTAssertEqual(error as? VaultEditError, .incompatibleValue(type))
            }
        }
        XCTAssertEqual(field.value, .text("Not a number"))
    }

    func testNonfiniteNumberConversionIsRejected() {
        for text in ["nan", "inf", "1e999"] {
            let field = VaultField(key: "n", label: "Number", value: .text(text))
            XCTAssertThrowsError(try field.changingType(to: .number))
        }
    }

    func testTypedConversionsStoreTheValueTheControlWillShow() throws {
        let number = VaultField(key: "n", label: "Number", value: .text("-12.5"))
        XCTAssertEqual(try number.changingType(to: .number).value, .number(-12.5))
        let boolean = VaultField(key: "b", label: "Boolean", value: .text("true"))
        XCTAssertEqual(try boolean.changingType(to: .boolean).value, .boolean(true))
        let empty = VaultField(key: "d", label: "Date")
        let now = Date(timeIntervalSince1970: 12345)
        XCTAssertEqual(try empty.changingType(to: .date, now: now).value, .date(nil))
        XCTAssertEqual(try empty.changingType(to: .date, now: now).insertionText, "")
        XCTAssertEqual(try empty.changingType(to: .boolean).value, .boolean(false))
    }

    func testConfirmedCategoryDeletionRejectsAChangedSnapshot() throws {
        let confirmed = VaultCategory(name: "Before import")
        var imported = confirmed
        imported.name = "Imported"
        var payload = VaultPayload(categories: [imported])
        XCTAssertThrowsError(try payload.deleteCategory(confirmed)) { error in
            XCTAssertEqual(error as? VaultEditError, .staleConfirmation)
        }
        XCTAssertEqual(payload.categories, [imported])
    }

    func testConfirmedProfileDeletionRejectsAChangedSnapshot() throws {
        let confirmed = Profile(name: "Before import")
        var imported = confirmed
        imported.name = "Imported"
        var payload = VaultPayload(profiles: [imported])
        XCTAssertThrowsError(try payload.deleteProfile(confirmed))
        XCTAssertEqual(payload.profiles, [imported])
    }

    func testConfirmedItemDeletionRejectsAChangedSnapshot() throws {
        let confirmed = VaultItem(title: "Before import")
        var imported = confirmed
        imported.title = "Imported"
        var payload = VaultPayload(items: [imported])
        XCTAssertThrowsError(try payload.deleteItem(confirmed))
        XCTAssertEqual(payload.items, [imported])
    }

    func testConfirmedDeletionAcceptsUnchangedSnapshots() throws {
        let category = VaultCategory(name: "Category")
        let profile = Profile(name: "Profile")
        let item = VaultItem(title: "Item", categoryID: category.id, profileID: profile.id)
        var payload = VaultPayload(profiles: [profile], categories: [category], items: [item])
        try payload.deleteItem(item)
        try payload.deleteCategory(category)
        try payload.deleteProfile(profile)
        XCTAssertTrue(payload.items.isEmpty)
        XCTAssertTrue(payload.categories.isEmpty)
        XCTAssertTrue(payload.profiles.isEmpty)
    }

    func testValidationSummaryIsEmptyForAValidItem() {
        let field = VaultField(key: "k", label: "L", type: .text)
        XCTAssertTrue(VaultItem(title: "T", fields: [field]).validationSummary.isEmpty)
    }
}
