import AppKit
import ApplicationServices

/// Non-sendable holder for the captured Accessibility element. The engine only
/// touches it on the main actor.
public final class TargetHandle {
    public let element: AXUIElement
    public let role: String?
    public let isSettableValue: Bool
    public let isSettableSelectedText: Bool
    public let app: NSRunningApplication?
    public let capturedAt: Date
    /// Where the user right-clicked, so the caret can be placed there before
    /// typing. Nil for targets captured from keyboard focus.
    public let clickPoint: CGPoint?

    public init(element: AXUIElement, role: String?, isSettableValue: Bool, isSettableSelectedText: Bool, app: NSRunningApplication?, capturedAt: Date = Date(), clickPoint: CGPoint? = nil) {
        self.element = element
        self.role = role
        self.isSettableValue = isSettableValue
        self.isSettableSelectedText = isSettableSelectedText
        self.app = app
        self.capturedAt = capturedAt
        self.clickPoint = clickPoint
    }
}
import AppKit
