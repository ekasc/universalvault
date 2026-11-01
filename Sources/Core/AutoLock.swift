import Foundation

/// Inactivity-based lock decision, separated from the session so the rule can
/// be tested without a running timer.
public enum AutoLock {
    public static let minimumMinutes = 1
    public static let maximumMinutes = 1440

    public static func clampedMinutes(_ configured: Int) -> Int {
        max(minimumMinutes, min(configured, maximumMinutes))
    }

    public static func shouldLock(lastActivity: Date, now: Date, configuredMinutes: Int) -> Bool {
        let seconds = Double(clampedMinutes(configuredMinutes) * 60)
        return now.timeIntervalSince(lastActivity) > seconds
    }
}
