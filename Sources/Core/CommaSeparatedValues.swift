import Foundation

/// Reversible text for tag and alias arrays, including imported commas and quotes.
public enum CommaSeparatedValues {
    public static func format(_ values: [String]) -> String {
        values.map { value in
            if value.isEmpty || value.contains(where: { ",\"\n\r".contains($0) })
                || value != value.trimmingCharacters(in: .whitespacesAndNewlines) {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }.joined(separator: ", ")
    }

    /// An unfinished or invalid quoted value stays in the editor, not the vault.
    public static func parse(_ text: String) -> [String]? {
        let characters = Array(text)
        var values: [String] = []
        var value = ""
        var quoted = false
        var inQuotes = false
        var closedQuote = false
        var index = 0

        func appendValue() {
            let result = quoted ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
            if quoted || !result.isEmpty { values.append(result) }
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        value.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                        closedQuote = true
                    }
                } else {
                    value.append(character)
                }
            } else if character == "," {
                appendValue()
                value = ""
                quoted = false
                closedQuote = false
            } else if character == "\"" {
                guard !quoted, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                value = ""
                quoted = true
                inQuotes = true
            } else if closedQuote {
                guard character.isWhitespace else { return nil }
            } else {
                value.append(character)
            }
            index += 1
        }
        guard !inQuotes else { return nil }
        appendValue()
        return values
    }
}
