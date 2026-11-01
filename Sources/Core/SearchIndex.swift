import Foundation

/// The query path for Quick Fill, built once per vault version.
///
/// `SearchEngine` lowercases every label, key, alias, title, and tag on each
/// keystroke. That is invisible on a small vault and measurable on a large one,
/// so the same scoring runs against prepared strings instead. Ordering and scores
/// match `SearchEngine` exactly; the difference is only where the work happens.
public struct SearchIndex: Sendable {
    public let updatedAt: Date
    /// Sealing an item does not touch `updatedAt`, so the number of locked items
    /// is part of the cache identity: an index built while an item was open must
    /// not answer after the item is sealed.
    public let lockedItemCount: Int
    private let items: [Item]

    private struct Item: Sendable {
        let item: VaultItem
        let title: String
        let tags: [String]
        let categoryName: String?
        let profileName: String?
        let fields: [Field]

        struct Field: Sendable {
            let field: VaultField
            let label: String
            let key: String
            let aliases: [String]
        }
    }

    public init(payload: VaultPayload) {
        updatedAt = payload.updatedAt
        lockedItemCount = payload.items.filter(\.isLocked).count
        var categories: [UUID: String] = [:]
        categories.reserveCapacity(payload.categories.count)
        for category in payload.categories where categories[category.id] == nil {
            categories[category.id] = category.name
        }
        var profiles: [UUID: String] = [:]
        profiles.reserveCapacity(payload.profiles.count)
        for profile in payload.profiles where profiles[profile.id] == nil {
            profiles[profile.id] = profile.name
        }

        // Item order is the display order, so the empty query needs no sort.
        items = payload.items
            .sorted { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder ? lhs.title < rhs.title : lhs.sortOrder < rhs.sortOrder
            }
            .map { item in
                Item(
                    item: item,
                    title: item.title.lowercased(),
                    tags: item.tags.map { $0.lowercased() },
                    categoryName: item.categoryID.flatMap { categories[$0] },
                    profileName: item.profileID.flatMap { profiles[$0] },
                    fields: item.fields
                        .sorted { $0.sortOrder < $1.sortOrder }
                        .map { field in
                            Item.Field(
                                field: field,
                                label: field.label.lowercased(),
                                key: field.key.lowercased(),
                                aliases: field.aliases.map { $0.lowercased() })
                        })
            }
    }

    public func search(query: String) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            var all: [SearchResult] = []
            all.reserveCapacity(items.reduce(0) { $0 + $1.fields.count })
            for item in items {
                for field in item.fields {
                    all.append(result(field, in: item, score: 0))
                }
            }
            return all
        }

        var results: [SearchResult] = []
        for item in items {
            guard !item.fields.isEmpty else { continue }
            // Title and tag matches apply to every field of the item, so they are
            // evaluated once per item rather than once per field.
            let titleScore = item.title.contains(q) ? 15 : 0
            let tagScore = titleScore == 0 && item.tags.contains(where: { $0.contains(q) }) ? 10 : 0
            for field in item.fields {
                var score = 0
                if field.label == q { score += 100 }
                else if field.label.hasPrefix(q) { score += 60 }
                else if field.label.contains(q) { score += 40 }
                if field.key.contains(q) { score += 20 }
                for alias in field.aliases {
                    if alias == q { score += 90 }
                    else if alias.hasPrefix(q) { score += 50 }
                    else if alias.contains(q) { score += 30 }
                }
                score += titleScore
                score += tagScore
                if score > 0 {
                    results.append(result(field, in: item, score: score))
                }
            }
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.field.sortOrder < rhs.field.sortOrder
        }
        return results
    }

    private func result(_ field: Item.Field, in item: Item, score: Int) -> SearchResult {
        SearchResult(
            field: field.field,
            item: item.item,
            categoryName: item.categoryName,
            profileName: item.profileName,
            score: score)
    }
}
