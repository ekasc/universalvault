import Foundation

public struct SearchEngine {
    public init() {}

    public func search(query: String, payload: VaultPayload) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            // Return all fields sorted by recent? just all.
            return payload.items.flatMap { item in
                item.fields.map { f in
                    SearchResult(field: f, item: item,
                                 categoryName: categoryName(for: item, payload: payload),
                                 profileName: profileName(for: item, payload: payload), score: 0)
                }
            }.sorted { $0.field.sortOrder < $1.field.sortOrder }
        }

        var results: [SearchResult] = []
        for item in payload.items {
            let cat = categoryName(for: item, payload: payload)
            let prof = profileName(for: item, payload: payload)
            for field in item.fields {
                var score = 0
                let labelL = field.label.lowercased()
                let keyL = field.key.lowercased()
                if labelL == q { score += 100 }
                else if labelL.hasPrefix(q) { score += 60 }
                else if labelL.contains(q) { score += 40 }
                if keyL.contains(q) { score += 20 }
                for alias in field.aliases {
                    let a = alias.lowercased()
                    if a == q { score += 90 }
                    else if a.hasPrefix(q) { score += 50 }
                    else if a.contains(q) { score += 30 }
                }
                if item.title.lowercased().contains(q) { score += 15 }
                for tag in item.tags {
                    if tag.lowercased().contains(q) { score += 10 }
                }
                if score > 0 {
                    results.append(SearchResult(field: field, item: item, categoryName: cat, profileName: prof, score: score))
                }
            }
        }
        return results.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.field.sortOrder < b.field.sortOrder
        }
    }

    private func categoryName(for item: VaultItem, payload: VaultPayload) -> String? {
        guard let cid = item.categoryID else { return nil }
        return payload.categories.first(where: { $0.id == cid })?.name
    }
    private func profileName(for item: VaultItem, payload: VaultPayload) -> String? {
        guard let pid = item.profileID else { return nil }
        return payload.profiles.first(where: { $0.id == pid })?.name
    }
}

public struct Templates {
    public static func all() -> [(name: String, icon: String, build: () -> VaultItem)] {
        return [
            ("Identity", "person", identity),
            ("Address", "mappin", address),
            ("Payment Card", "creditcard", paymentCard),
            ("Passport", "book", passport),
            ("Driver's Licence", "car", driversLicence),
            ("Education", "graduationcap", education),
            ("Employment", "briefcase", employment),
            ("Custom", "square.grid.2x2", custom),
        ]
    }

    private static func item(_ title: String, tags: [String] = [], fields: [VaultField]) -> VaultItem {
        let f = fields.enumerated().map { idx, field in
            var x = field; x.sortOrder = idx; return x
        }
        return VaultItem(title: title, tags: tags, fields: f)
    }
    private static func f(_ key: String, _ label: String, _ type: FieldType, sensitivity: SensitivityLevel = .normal, aliases: [String] = []) -> VaultField {
        VaultField(key: key, label: label, type: type, sensitivity: sensitivity, aliases: aliases)
    }

    public static func identity() -> VaultItem {
        item("Identity", tags: ["personal"], fields: [
            f("givenName","First Name",.text, aliases:["Given Name"]),
            f("familyName","Last Name",.text, aliases:["Surname"]),
            f("fullName","Full Name",.text),
            f("email","Email",.email),
            f("phone","Phone",.phone),
            f("dob","Date of Birth",.date),
        ])
    }
    public static func address() -> VaultItem {
        item("Address", tags: ["address"], fields: [
            f("street1","Street Address",.text),
            f("street2","Address Line 2",.text),
            f("city","City",.text),
            f("state","State/Province",.text),
            f("postal","Postal Code",.text),
            f("country","Country",.text),
        ])
    }
    public static func paymentCard() -> VaultItem {
        item("Payment Card", tags: ["payment"], fields: [
            f("cardholder","Cardholder Name",.text),
            f("number","Card Number",.text, sensitivity: .critical, aliases: ["PAN"]),
            f("expiry","Expiration Date",.text, sensitivity: .sensitive),
            f("billing","Billing Address",.multiline, sensitivity: .sensitive),
        ])
    }
    public static func passport() -> VaultItem {
        item("Passport", tags: ["document"], fields: [
            f("number","Passport Number",.text, sensitivity: .critical),
            f("issuingCountry","Issuing Country",.text),
            f("issueDate","Issue Date",.date),
            f("expiryDate","Expiration Date",.date),
            f("nationality","Nationality",.text),
        ])
    }
    public static func driversLicence() -> VaultItem {
        item("Driver's Licence", tags: ["document"], fields: [
            f("number","Licence Number",.text, sensitivity: .critical),
            f("state","Issuing State/Province",.text),
            f("expiry","Expiration Date",.date),
            f("class","Class",.text),
        ])
    }
    public static func education() -> VaultItem {
        item("Education", tags: ["education"], fields: [
            f("institution","Institution",.text),
            f("degree","Degree",.text),
            f("field","Field of Study",.text),
            f("startDate","Start Date",.date),
            f("endDate","End Date",.date),
            f("gpa","GPA",.text),
        ])
    }
    public static func employment() -> VaultItem {
        item("Employment", tags: ["work"], fields: [
            f("employer","Employer",.text),
            f("title","Job Title",.text),
            f("startDate","Start Date",.date),
            f("endDate","End Date",.date),
            f("salary","Salary",.text, sensitivity: .sensitive),
            f("manager","Manager",.text),
        ])
    }
    public static func custom() -> VaultItem { item("Custom Item", tags: [], fields: []) }
}
