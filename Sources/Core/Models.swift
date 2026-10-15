import Foundation

public enum FieldType: String, Codable, CaseIterable, Sendable {
    case text, multiline, number, email, url, date, phone, secret, boolean, custom
}

public enum SensitivityLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case normal, sensitive, critical

    public static func < (lhs: SensitivityLevel, rhs: SensitivityLevel) -> Bool {
        let order: [SensitivityLevel] = [.normal, .sensitive, .critical]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

public enum FieldValue: Codable, Equatable, Sendable {
    case text(String)
    case multiline(String)
    case number(Double?)
    case email(String)
    case url(String)
    case date(Date)
    case phone(String)
    case secret(String)
    case boolean(Bool)
    case custom(String)

    public var storageDescription: String {
        switch self {
        case .text(let v), .multiline(let v), .email(let v), .url(let v),
             .phone(let v), .secret(let v), .custom(let v): return v
        case .number(let v): return v.map { String($0) } ?? ""
        case .date(let v): return String(v.timeIntervalSince1970)
        case .boolean(let v): return v ? "true" : "false"
        }
    }

    public var insertionText: String {
        switch self {
        case .text(let v), .multiline(let v), .email(let v), .url(let v),
             .phone(let v), .secret(let v), .custom(let v): return v
        case .number(let v): return v.map { formatNumber($0) } ?? ""
        case .date(let v): return Self.isoDateFormatter.string(from: v)
        case .boolean(let v): return v ? "true" : "false"
        }
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private func formatNumber(_ d: Double) -> String {
        guard d.isFinite else { return "" }
        if d == d.rounded() && d >= Double(Int.min) && d < Double(Int.max) {
            return String(Int(d))
        }
        if d == d.rounded() {
            return String(format: "%.0f", d)
        }
        return String(d)
    }
}

extension VaultField {
    public var insertionText: String {
        if case .date(let d) = value {
            let format = preferredInsertFormat ?? "yyyy-MM-dd"
            if format.lowercased() == "locale-short" {
                let f = DateFormatter()
                f.dateStyle = .short
                f.timeStyle = .none
                return f.string(from: d)
            }
            let f = DateFormatter()
            f.dateFormat = format
            return f.string(from: d)
        }
        return value.insertionText
    }
}

public struct VaultField: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var key: String
    public var label: String
    public var type: FieldType
    public var value: FieldValue
    public var sensitivity: SensitivityLevel
    public var aliases: [String]
    public var preferredInsertFormat: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), key: String, label: String, type: FieldType = .text,
                value: FieldValue = .text(""), sensitivity: SensitivityLevel = .normal,
                aliases: [String] = [], preferredInsertFormat: String? = nil,
                sortOrder: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.key = key
        self.label = label
        self.type = type
        self.value = value
        self.sensitivity = sensitivity
        self.aliases = aliases
        self.preferredInsertFormat = preferredInsertFormat
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct VaultItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var categoryID: UUID?
    public var profileID: UUID?
    public var icon: String?
    public var tags: [String]
    public var fields: [VaultField]
    public var createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Int

    public init(id: UUID = UUID(), title: String, categoryID: UUID? = nil, profileID: UUID? = nil,
                icon: String? = nil, tags: [String] = [], fields: [VaultField] = [],
                createdAt: Date = Date(), updatedAt: Date = Date(), sortOrder: Int = 0) {
        self.id = id
        self.title = title
        self.categoryID = categoryID
        self.profileID = profileID
        self.icon = icon
        self.tags = tags
        self.fields = fields
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }
}

public struct Category: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var sortOrder: Int
    public var colorHex: String?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, sortOrder: Int = 0, colorHex: String? = nil) {
        self.id = id; self.name = name; self.parentID = parentID; self.sortOrder = sortOrder; self.colorHex = colorHex
    }
}

public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.sortOrder = sortOrder
    }
}

public struct VaultSettings: Codable, Equatable, Sendable {
    public var autoLockMinutes: Int
    public var requireAuthForSensitiveInsert: Bool
    public var showValuePreviews: Bool

    public init(autoLockMinutes: Int = 5, requireAuthForSensitiveInsert: Bool = true, showValuePreviews: Bool = false) {
        self.autoLockMinutes = autoLockMinutes
        self.requireAuthForSensitiveInsert = requireAuthForSensitiveInsert
        self.showValuePreviews = showValuePreviews
    }
}

public struct VaultPayload: Codable, Sendable {
    public var schemaVersion: Int
    public var vaultID: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var profiles: [Profile]
    public var categories: [Category]
    public var items: [VaultItem]
    public var settings: VaultSettings

    public init(schemaVersion: Int = 1, vaultID: UUID = UUID(), createdAt: Date = Date(),
                updatedAt: Date = Date(), profiles: [Profile] = [], categories: [Category] = [],
                items: [VaultItem] = [], settings: VaultSettings = VaultSettings()) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.profiles = profiles
        self.categories = categories
        self.items = items
        self.settings = settings
    }
}

public struct SearchResult: Identifiable, Sendable {
    public let id: UUID // field id
    public let field: VaultField
    public let item: VaultItem
    public let categoryName: String?
    public let profileName: String?
    public let score: Int

    public init(field: VaultField, item: VaultItem, categoryName: String?, profileName: String?, score: Int) {
        self.id = field.id
        self.field = field
        self.item = item
        self.categoryName = categoryName
        self.profileName = profileName
        self.score = score
    }
}

public enum Validation {
    public static func validateField(_ field: VaultField) -> [String] {
        var errors: [String] = []
        if field.label.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Label is required.") }
        if field.key.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Key is required.") }
        return errors
    }
    public static func validateItem(_ item: VaultItem) -> [String] {
        var errors: [String] = []
        if item.title.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Title is required.") }
        return errors
    }
}
