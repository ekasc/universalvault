import Foundation

public enum VaultEditError: Error, LocalizedError, Equatable {
    case emptyName
    case itemMissing
    case itemChanged
    case incompatibleValue(FieldType)
    case staleConfirmation

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Name cannot be empty."
        case .itemMissing: return "This item no longer exists. Your edits were not saved."
        case .itemChanged: return "This item changed elsewhere. Your edits were not saved. Reload the saved item before editing."
        case .incompatibleValue(let type): return "The current value cannot be converted to \(type.rawValue). Keep its type or clear the value first."
        case .staleConfirmation: return "The vault changed after this action was opened. Reopen the action and try again."
        }
    }
}

private func trimmedName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VaultEditError.emptyName }
    return trimmed
}

public extension VaultItem {
    /// Equality ignoring `updatedAt`, which every save stamps. Used to notice a
    /// change made from somewhere else — a backup import, or another editor.
    func hasSameContent(as other: VaultItem) -> Bool {
        var mine = self
        var theirs = other
        mine.updatedAt = .distantPast
        theirs.updatedAt = .distantPast
        return mine == theirs
    }

    /// Keeps other edits saveable while a required name is temporarily empty.
    /// Missing category and profile assignments cannot be restored by a stale draft.
    func sanitized(previous: VaultItem?, categoryIDs: Set<UUID>, profileIDs: Set<UUID>) -> VaultItem {
        var result = self

        if result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = (previous?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result.title = fallback.isEmpty ? "Untitled" : fallback
        }

        if let categoryID = result.categoryID, !categoryIDs.contains(categoryID) {
            result.categoryID = nil
        }
        if let profileID = result.profileID, !profileIDs.contains(profileID) {
            result.profileID = nil
        }

        let savedFields = Dictionary((previous?.fields ?? []).map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        result.fields = result.fields.enumerated().map { index, field in
            var field = field
            if field.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                field.key = savedFields[field.id]?.key ?? "field\(index + 1)"
            }
            if field.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                field.label = savedFields[field.id]?.label ?? field.key
            }
            if field.type == .secret { field.sensitivity = max(.sensitive, field.sensitivity) }
            return field
        }

        return result
    }

    /// Names the problem for the editor's banner, preferring whatever the user
    /// can still see on screen over a generic placeholder.
    var validationSummary: String {
        var errors = Validation.validateItem(self).map { "item: \($0)" }
        for (index, field) in fields.enumerated() {
            let name = field.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (field.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Field \(index + 1)" : field.key)
                : field.label
            errors.append(contentsOf: Validation.validateField(field).map { "\(name): \($0)" })
        }
        return errors.joined(separator: " ")
    }
}

public extension VaultField {
    /// A type change must not hide an existing value or silently replace it.
    func changingType(to type: FieldType, now: Date = Date()) throws -> VaultField {
        guard type != self.type else { return self }
        var field = self
        let text = value.insertionText
        switch type {
        case .text: field.value = .text(text)
        case .multiline: field.value = .multiline(text)
        case .email: field.value = .email(text)
        case .url: field.value = .url(text)
        case .phone: field.value = .phone(text)
        case .custom: field.value = .custom(text)
        case .secret:
            field.value = .secret(text)
            field.sensitivity = max(.sensitive, sensitivity)
        case .number:
            if text.isEmpty {
                field.value = .number(nil)
            } else {
                guard let number = Double(text), number.isFinite else { throw VaultEditError.incompatibleValue(type) }
                field.value = .number(number)
            }
        case .boolean:
            switch text.lowercased() {
            case "true": field.value = .boolean(true)
            case "false", "": field.value = .boolean(false)
            default: throw VaultEditError.incompatibleValue(type)
            }
        case .date:
            guard text.isEmpty else { throw VaultEditError.incompatibleValue(type) }
            field.value = .date(nil)
        }
        field.type = type
        return field
    }
}

public extension VaultPayload {
    /// Called when a queued edit runs, not when it is enqueued. Comparing with
    /// the latest saved item preserves rapid edits followed by a revert.
    func itemForSaving(_ draft: VaultItem, replacing baseline: VaultItem) throws -> VaultItem? {
        guard let live = items.first(where: { $0.id == draft.id }) else {
            throw VaultEditError.itemMissing
        }
        let categoryIDs = Set(categories.map(\.id))
        let profileIDs = Set(profiles.map(\.id))
        var reconciled = baseline
        if let id = reconciled.categoryID, !categoryIDs.contains(id) { reconciled.categoryID = nil }
        if let id = reconciled.profileID, !profileIDs.contains(id) { reconciled.profileID = nil }
        guard live.hasSameContent(as: reconciled) else { throw VaultEditError.itemChanged }
        let clean = draft.sanitized(previous: live, categoryIDs: categoryIDs, profileIDs: profileIDs)
        return clean.hasSameContent(as: live) ? nil : clean
    }

    // MARK: - Items

    @discardableResult
    mutating func addItem(title: String = "New Item", categoryID: UUID? = nil, profileID: UUID? = nil) -> UUID {
        let item = VaultItem(title: title,
                             categoryID: categoryID,
                             profileID: profileID,
                             sortOrder: VaultBrowser.nextItemSortOrder(items))
        items.append(item)
        return item.id
    }

    @discardableResult
    mutating func duplicateItem(_ id: UUID) -> UUID? {
        guard var copy = items.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID()
        copy.title = "\(copy.title) copy"
        copy.sortOrder = VaultBrowser.nextItemSortOrder(items)
        copy.createdAt = Date()
        copy.updatedAt = Date()
        // Fresh field identities, so the two items never share field ids.
        copy.fields = copy.fields.map { field in
            var f = field
            f.id = UUID()
            return f
        }
        items.append(copy)
        return copy.id
    }

    mutating func updateItem(_ id: UUID, _ update: (inout VaultItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        update(&items[index])
        items[index].updatedAt = Date()
    }

    mutating func deleteItem(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func deleteItem(_ confirmed: VaultItem) throws {
        guard items.first(where: { $0.id == confirmed.id }) == confirmed else { throw VaultEditError.staleConfirmation }
        deleteItem(confirmed.id)
    }

    // MARK: - Categories

    /// Creates a category and returns its id. A parent that does not exist is
    /// dropped rather than stored, so a stale id cannot create an invisible
    /// branch of the sidebar.
    @discardableResult
    mutating func addCategory(name: String, parentID: UUID? = nil) throws -> UUID {
        let trimmed = try trimmedName(name)
        let validParent = parentID.flatMap { candidate in
            categories.contains { $0.id == candidate } ? candidate : nil
        }
        let category = VaultCategory(name: trimmed,
                                parentID: validParent,
                                sortOrder: VaultBrowser.nextSortOrder(categories, parentID: validParent))
        categories.append(category)
        return category.id
    }

    mutating func renameCategory(_ id: UUID, to name: String) throws {
        let trimmed = try trimmedName(name)
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].name = trimmed
    }

    /// Removes the category only. Child categories move up to its parent, and
    /// items in it become uncategorized. No item is ever deleted along with a
    /// category: this is a vault, and losing data to a sidebar action would be
    /// indefensible.
    mutating func deleteCategory(_ id: UUID) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        let parent = categories[index].parentID
        categories.remove(at: index)
        for child in categories.indices where categories[child].parentID == id {
            categories[child].parentID = parent
        }
        for item in items.indices where items[item].categoryID == id {
            items[item].categoryID = nil
        }
    }

    mutating func deleteCategory(_ confirmed: VaultCategory) throws {
        guard categories.first(where: { $0.id == confirmed.id }) == confirmed else { throw VaultEditError.staleConfirmation }
        deleteCategory(confirmed.id)
    }

    // MARK: - Profiles

    @discardableResult
    mutating func addProfile(name: String) throws -> UUID {
        let trimmed = try trimmedName(name)
        let profile = Profile(name: trimmed, sortOrder: profiles.count)
        profiles.append(profile)
        return profile.id
    }

    mutating func renameProfile(_ id: UUID, to name: String) throws {
        let trimmed = try trimmedName(name)
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
    }

    mutating func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        for item in items.indices where items[item].profileID == id {
            items[item].profileID = nil
        }
    }

    mutating func deleteProfile(_ confirmed: Profile) throws {
        guard profiles.first(where: { $0.id == confirmed.id }) == confirmed else { throw VaultEditError.staleConfirmation }
        deleteProfile(confirmed.id)
    }
}
