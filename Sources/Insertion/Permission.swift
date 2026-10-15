import Foundation
import ApplicationServices

public enum PermissionStatus { case granted, denied, unknown }

public struct AccessibilityPermission {
    public init() {}
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
    public static func requestPrompt() -> Bool {
        let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
