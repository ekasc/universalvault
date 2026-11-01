import os

/// Insertion diagnostics. Outcomes and roles only — never field values or item
/// titles — so a failed fill can be explained without exposing vault data.
enum Diagnostics {
    static let insertion = Logger(subsystem: "com.universalvault.app", category: "insertion")

    static func trace(_ message: String) {
        insertion.notice("\(message, privacy: .public)")
    }
}
