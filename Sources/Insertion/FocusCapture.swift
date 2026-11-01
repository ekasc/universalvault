import Foundation
import ApplicationServices
import AppKit

public final class FocusCapture {
    /// The last application that was frontmost without being UniversalVault.
    /// Clicking the status item can make this app active before the palette
    /// opens, and the palette still needs to know which app the user was typing
    /// in, so the status-item path may fall back to this.
    private final class LastExternalApp: @unchecked Sendable {
        private let lock = NSLock()
        private var app: NSRunningApplication?

        func set(_ app: NSRunningApplication?) {
            lock.lock()
            defer { lock.unlock() }
            self.app = app
        }

        func get() -> NSRunningApplication? {
            lock.lock()
            defer { lock.unlock() }
            return app
        }
    }

    private let lastExternal = LastExternalApp()
    private var activationObserver: (any NSObjectProtocol)?

    /// Only these roles can receive typed text. Capturing a focused button made
    /// the palette claim a target it could never fill.
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    public init() {
        let store = lastExternal
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Seed from launch: if the user has been in one app since before this
        // process started, no activation notification will ever fire for it.
        if let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ownPID
        {
            store.set(front)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                app.processIdentifier != ownPID
            else { return }
            store.set(app)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// `allowLastExternal` is for invocations that start in our own UI (the
    /// status item). The global shortcut keeps the strict behaviour: it only
    /// targets an application that is frontmost right now.
    public func capture(allowLastExternal: Bool = false) -> TargetHandle? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ownPID,
            let handle = handle(for: front)
        {
            return handle
        }
        guard allowLastExternal, let last = lastExternal.get(),
            last.processIdentifier != ownPID
        else { return nil }
        return handle(for: last)
    }

    private func handle(for app: NSRunningApplication) -> TargetHandle? {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let el = focused,
            CFGetTypeID(el) == AXUIElementGetTypeID()
        else { return nil }
        let element = el as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String
        guard let role, Self.editableRoles.contains(role) else { return nil }

        var valueSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)

        var selSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &selSettable)

        return TargetHandle(
            element: element, role: role, isSettableValue: valueSettable.boolValue,
            isSettableSelectedText: selSettable.boolValue, app: app, capturedAt: Date())
    }

    public static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// The editable element under a screen point, for the right-click menu. The
    /// element at the exact point is often a glyph or a child inside a web
    /// input, so walk up until an editable role is found.
    public func capture(at point: CGPoint) -> TargetHandle? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
                == .success,
            var current = hit
        else { return nil }

        for _ in 0..<8 {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, Self.editableRoles.contains(role) {
                var pid: pid_t = 0
                AXUIElementGetPid(current, &pid)
                var valueSettable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(
                    current, kAXValueAttribute as CFString, &valueSettable)
                var selSettable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(
                    current, kAXSelectedTextAttribute as CFString, &selSettable)
                return TargetHandle(
                    element: current, role: role, isSettableValue: valueSettable.boolValue,
                    isSettableSelectedText: selSettable.boolValue,
                    app: NSRunningApplication(processIdentifier: pid), capturedAt: Date(),
                    clickPoint: point)
            }
            var parentRef: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef)
                    == .success,
                let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }
}
