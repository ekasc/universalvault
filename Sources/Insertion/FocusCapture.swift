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

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String

        var valueSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)

        var selSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selSettable)

        return TargetHandle(
            element: element,
            role: role,
            isSettableValue: valueSettable.boolValue,
            isSettableSelectedText: selSettable.boolValue,
            app: app,
            frame: Self.frame(of: element),
            isSecureField: Self.isSecure(subrole: subrole, element: element)
        )
    }

    public static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    // MARK: - Geometry

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard withUnsafeMutablePointer(to: &point, { AXValueGetValue(posRef as! AXValue, .cgPoint, $0) }),
              withUnsafeMutablePointer(to: &size, { AXValueGetValue(sizeRef as! AXValue, .cgSize, $0) }),
              size.width > 0, size.height > 0 else { return nil }

        return cocoaRect(CGRect(origin: point, size: size))
    }

    /// AX uses the top-left of the primary display with y growing downward;
    /// Cocoa screen coordinates use the bottom-left with y growing upward.
    private static func cocoaRect(_ axRect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = CGRect(
            x: axRect.minX,
            y: primary.frame.height - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
        // Reject nonsense rectangles from apps that report the whole window.
        guard flipped.width < 4000, flipped.height < 2000 else { return nil }
        return flipped
    }

    // MARK: - Field kind

    private static func isSecure(subrole: String?, element: AXUIElement) -> Bool {
        if subrole == "AXSecureTextField" { return true }

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        var placeholderRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &placeholderRef)

        let hints = "\(descRef as? String ?? "") \(placeholderRef as? String ?? "")".lowercased()
        return hints.contains("password") || hints.contains("passcode")
    }
}
