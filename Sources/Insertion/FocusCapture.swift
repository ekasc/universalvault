import Foundation
import ApplicationServices
import AppKit

public final class FocusCapture {
    public init() {}

    public func capture() -> TargetHandle? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let el = focused else { return nil }
        let element = el as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        var valueSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)

        var selSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selSettable)

        return TargetHandle(element: element, role: role, isSettableValue: valueSettable.boolValue,
                            isSettableSelectedText: selSettable.boolValue, app: app)
    }

    public static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
