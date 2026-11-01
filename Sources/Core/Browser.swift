import Foundation

/// What the vault window's sidebar currently points at.
public enum VaultSelection: Hashable, Sendable {
    case allItems
    case category(UUID)
    case profile(UUID)
}

/// A category flattened for display, with its indent depth.
public struct CategoryRow: Identifiable, Sendable, Equatable {
    public let category: VaultCategory
    public let depth: Int
    public var id: UUID { category.id }

    public init(category: VaultCategory, depth: Int) {
        self.category = category
        self.depth = depth
    }
}

/// Sidebar and list ordering, kept out of the views so it can be tested.
public enum VaultBrowser {
    public static func categoryRows(_ categories: [VaultCategory], collapsed: Set<UUID>) -> [CategoryRow] {
        var hiddenBelowDepth: Int?
        return categoryRows(categories).filter { row in
            if let depth = hiddenBelowDepth {
                if row.depth > depth { return false }
                hiddenBelowDepth = nil
            }
            if collapsed.contains(row.id) { hiddenBelowDepth = row.depth }
            return true
        }
    }

    /// Categories in display order, depth first.
    ///
    /// A category whose `parentID` does not resolve is treated as a root rather
    /// than dropped: a dangling parent must not make a category unreachable.
    /// Cyclic parent chains are broken at the point of re-entry so the flatten
    /// always terminates.
    public static func categoryRows(_ categories: [VaultCategory]) -> [CategoryRow] {
        let known = Set(categories.map(\.id))
        var childrenByParent: [UUID: [VaultCategory]] = [:]
        var roots: [VaultCategory] = []

        for category in categories {
            if let parent = category.parentID, known.contains(parent), parent != category.id {
                childrenByParent[parent, default: []].append(category)
            } else {
                roots.append(category)
            }
        }

        let byOrder: (VaultCategory, VaultCategory) -> Bool = { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        var rows: [CategoryRow] = []
        var visited: Set<UUID> = []

        func append(_ category: VaultCategory, depth: Int) {
            guard !visited.contains(category.id) else { return }
            visited.insert(category.id)
            rows.append(CategoryRow(category: category, depth: depth))
            for child in (childrenByParent[category.id] ?? []).sorted(by: byOrder) {
                append(child, depth: depth + 1)
            }
        }

        for root in roots.sorted(by: byOrder) { append(root, depth: 0) }

        // Anything left over sat in a cycle. Those are emitted flat at the root:
        // a cyclic parent link is not a hierarchy, so indenting one member under
        // another would state a relationship the data does not support.
        for orphan in categories.filter({ !visited.contains($0.id) }).sorted(by: byOrder) {
            guard !visited.contains(orphan.id) else { continue }
            visited.insert(orphan.id)
            rows.append(CategoryRow(category: orphan, depth: 0))
        }

        return rows
    }

    /// Items for the item list: filtered by sidebar selection, then by search
    /// text, then ordered.
    public static func items(_ items: [VaultItem], selection: VaultSelection, search: String = "") -> [VaultItem] {
        let scoped = items.filter { matches($0, selection: selection) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = query.isEmpty ? scoped : scoped.filter { matches($0, query: query) }
        return matched.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private static func matches(_ item: VaultItem, selection: VaultSelection) -> Bool {
        switch selection {
        case .allItems: return true
        case .category(let id): return item.categoryID == id
        case .profile(let id): return item.profileID == id
        }
    }

    /// Fields are matched as well as the item title, so searching for a value's
    /// label finds the item that holds it.
    private static func matches(_ item: VaultItem, query: String) -> Bool {
        if item.title.lowercased().contains(query) { return true }
        if item.tags.contains(where: { $0.lowercased().contains(query) }) { return true }
        return item.fields.contains { field in
            field.label.lowercased().contains(query)
                || field.key.lowercased().contains(query)
                || field.aliases.contains { $0.lowercased().contains(query) }
        }
    }

    /// Number of items in each category, for the sidebar's trailing counts.
    public static func itemCounts(_ items: [VaultItem]) -> (categories: [UUID: Int], profiles: [UUID: Int]) {
        var categories: [UUID: Int] = [:]
        var profiles: [UUID: Int] = [:]
        for item in items {
            if let id = item.categoryID { categories[id, default: 0] += 1 }
            if let id = item.profileID { profiles[id, default: 0] += 1 }
        }
        return (categories, profiles)
    }

    /// Next free sort order, so a newly created sibling lands at the end.
    public static func nextSortOrder(_ categories: [VaultCategory], parentID: UUID?) -> Int {
        let siblings = categories.filter { $0.parentID == parentID }
        let last = siblings.map(\.sortOrder).max() ?? -1
        return last == Int.max ? Int.max : last + 1
    }

    public static func nextItemSortOrder(_ items: [VaultItem]) -> Int {
        let last = items.map(\.sortOrder).max() ?? -1
        return last == Int.max ? Int.max : last + 1
    }
}

/// Insert-format choices offered for date fields.
public enum DateInsertFormat {
    /// Sentinel understood by `VaultField.insertionText`.
    public static let localeShort = "locale-short"
    public static let defaultFormat = "yyyy-MM-dd"

    public static let presets: [(label: String, value: String)] = [
        ("ISO date (2026-01-31)", defaultFormat),
        ("Local short (31/01/2026)", localeShort),
        ("US (01/31/2026)", "MM/dd/yyyy"),
        ("Day first (31/01/2026)", "dd/MM/yyyy"),
    ]

    public static func resolved(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return defaultFormat }
        return stored
    }

    public static func isPreset(_ value: String) -> Bool {
        presets.contains { $0.value == value }
    }
}
