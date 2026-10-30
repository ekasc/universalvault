import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

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
    /// Screen rectangle of the focused control, in Cocoa screen coordinates (origin bottom-left).
    public let frame: CGRect?
    /// True for password-style fields, used to put secrets first in the palette.
    public let isSecureField: Bool

    public init(element: AXUIElement, role: String?, isSettableValue: Bool, isSettableSelectedText: Bool,
                app: NSRunningApplication?, frame: CGRect? = nil, isSecureField: Bool = false) {
        self.element = element
        self.role = role
        self.isSettableValue = isSettableValue
        self.isSettableSelectedText = isSettableSelectedText
        self.app = app
        self.frame = frame
        self.isSecureField = isSecureField
    }
}
