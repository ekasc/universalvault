import Foundation

/// The read-only slice of the vault that a local agent may query.
///
/// The filter is deliberately narrow: an item must be marked shareable, must not
/// be protected, and only its fields that are neither sensitive nor critical are
/// included. A field whose type is `secret` is forced to at least sensitive by
/// validation, so credentials cannot reach this document.
public struct AgentProfile: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let title: String
        public let fields: [Field]
    }

    public struct Field: Codable, Equatable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public static let formatName = "universalvault.about-me"
    public static let currentVersion = 1

    public let format: String
    public let version: Int
    public let vaultUpdatedAt: Date
    public let generatedAt: Date
    public let items: [Item]

    /// Empty items are dropped: an item marked shareable whose fields are all
    /// sensitive has nothing to say to an agent.
    public static func build(from payload: VaultPayload, now: Date = Date()) -> AgentProfile {
        let items = payload.items
            .filter { $0.isShareableWithAgents && !$0.isSensitive }
            .sorted { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder ? lhs.title < rhs.title : lhs.sortOrder < rhs.sortOrder
            }
            .map { item in
                Item(
                    title: item.title,
                    fields: item.fields
                        .filter { $0.sensitivity == .normal && $0.type != .secret }
                        .sorted { $0.sortOrder < $1.sortOrder }
                        .map { Field(label: $0.label, value: $0.insertionText) })
            }
            .filter { !$0.fields.isEmpty }
        return AgentProfile(
            format: formatName,
            version: currentVersion,
            vaultUpdatedAt: payload.updatedAt,
            generatedAt: now,
            items: items)
    }

    /// Stable, sorted, pretty JSON so an agent can diff it and a human can read it.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// True when the item contributes nothing to the document, so the editor can
    /// say why it is not visible to agents.
    public static func sharesNothing(_ item: VaultItem) -> Bool {
        item.isSensitive
            || item.fields.allSatisfy { $0.sensitivity != .normal || $0.type == .secret }
    }
}
