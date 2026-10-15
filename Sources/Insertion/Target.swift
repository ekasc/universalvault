import Foundation
import ApplicationServices

public struct InsertionTarget: Sendable {
    public let bundleIdentifier: String?
    public let processID: pid_t
    public let createdAt: Date
    // AXUIElement not Sendable across; store as opaque pointer? We'll keep non-Sendable wrapper.
}

// Non-sendable holder for AX element
public final class TargetHandle {
    public let element: AXUIElement
    public let role: String?
    public let isSettableValue: Bool
    public let isSettableSelectedText: Bool
    public let app: NSRunningApplication?
    public let capturedAt: Date

    public init(element: AXUIElement, role: String?, isSettableValue: Bool, isSettableSelectedText: Bool, app: NSRunningApplication?, capturedAt: Date = Date()) {
        self.element = element
        self.role = role
        self.isSettableValue = isSettableValue
        self.isSettableSelectedText = isSettableSelectedText
        self.app = app
        self.capturedAt = capturedAt
    }
}
import AppKit
