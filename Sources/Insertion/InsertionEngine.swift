import Foundation
import ApplicationServices
import CoreGraphics
import AppKit
import Core

public enum InsertionOutcome: String, Sendable {
    case successVerified
    case successUnverified
    case failed
    case canceled
    case rejected
    case partial
}

public enum InsertionError: Error, LocalizedError {
    case permissionDenied
    case targetInvalid
    case targetClosed
    case focusChanged
    case unsupportedControl
    case readOnly
    case axFailed
    case keyboardFailed
    case valueEmpty
    case expired
    case sessionChanged

    public var errorDescription: String? { rawValue }
    private var rawValue: String {
        switch self {
        case .permissionDenied: return "Accessibility permission denied."
        case .targetInvalid: return "Target no longer valid."
        case .targetClosed: return "Target application closed."
        case .focusChanged: return "Focus changed; insertion canceled for safety."
        case .unsupportedControl: return "Unsupported input control."
        case .readOnly: return "Target is read-only."
        case .axFailed: return "Accessibility insertion failed."
        case .keyboardFailed: return "Keyboard insertion failed."
        case .valueEmpty: return "Value is empty."
        case .expired: return "Insertion transaction expired."
        case .sessionChanged: return "Vault session changed; insertion canceled."
        }
    }
}

public struct InsertionResult {
    public let outcome: InsertionOutcome
    public let method: String
    public let error: InsertionError?
    public init(outcome: InsertionOutcome, method: String, error: InsertionError? = nil) {
        self.outcome = outcome; self.method = method; self.error = error
    }
}

public final class InsertionEngine {
    public init() {}

    @MainActor private static func stringValue(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    @MainActor private static func waitForActivation(pid: pid_t, deadline: Date) async -> Bool {
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            do {
                try await Task.sleep(nanoseconds: 16_000_000)
            } catch {
                return false
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    @MainActor public func insert(
        value: String,
        into target: TargetHandle,
        originalBundleID: String?,
        originalPID: pid_t,
        transactionID: UUID,
        sessionGeneration: UUID,
        currentSessionGeneration: @escaping () -> UUID,
        isTransactionActive: @escaping () -> Bool = { true }
    ) async -> InsertionResult {
        guard !value.isEmpty else { return InsertionResult(outcome: .failed, method: "none", error: .valueEmpty) }
        if !AccessibilityPermission.isTrusted() { return InsertionResult(outcome: .rejected, method: "none", error: .permissionDenied) }

        // Transaction expiry (short-lived)
        if Date().timeIntervalSince(target.capturedAt) > 10 {
            return InsertionResult(outcome: .canceled, method: "none", error: .expired)
        }
        if !isTransactionActive() {
            return InsertionResult(outcome: .canceled, method: "none", error: .sessionChanged)
        }
        _ = transactionID

        // Session must be unchanged
        if currentSessionGeneration() != sessionGeneration || !isTransactionActive() {
            return InsertionResult(outcome: .canceled, method: "none", error: .sessionChanged)
        }

        let pid = target.app?.processIdentifier ?? originalPID

        // Validate process alive
        if !FocusCapture.isProcessAlive(pid) {
            return InsertionResult(outcome: .failed, method: "none", error: .targetClosed)
        }

        // Validate original application identity
        if let bundle = originalBundleID, let app = target.app, let actual = app.bundleIdentifier, bundle != actual {
            return InsertionResult(outcome: .rejected, method: "none", error: .focusChanged)
        }

        // Permit only the expected focus transition. UniversalVault may be active
        // because the palette was just closed, or the captured target may still
        // be active. A third application becoming active means the original
        // target no longer has the intended interaction context.
        guard let currentFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }
        let vaultPID = ProcessInfo.processInfo.processIdentifier
        if currentFrontmost != pid && currentFrontmost != vaultPID {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }

        // Validate focus and role before insertion
        var focusedRef: CFTypeRef?
        let axApp = AXUIElementCreateApplication(pid)
        let copyStatus = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard copyStatus == .success, let focused = focusedRef else {
            return InsertionResult(outcome: .rejected, method: "none", error: .targetInvalid)
        }
        guard CFEqual(target.element, focused) else {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String, ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) else {
            return InsertionResult(outcome: .rejected, method: "none", error: .unsupportedControl)
        }
        var selectedTextWritable = DarwinBoolean(false)
        var valueWritable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &selectedTextWritable)
        _ = AXUIElementIsAttributeSettable(target.element, kAXValueAttribute as CFString, &valueWritable)
        if !(selectedTextWritable.boolValue || valueWritable.boolValue) {
            return InsertionResult(outcome: .rejected, method: "none", error: .readOnly)
        }

        // Strategy A: AX selected text
        if target.isSettableSelectedText {
            let before = Self.stringValue(of: target.element)
            let status = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, value as CFTypeRef)
            if status == .success {
                if before != nil {
                    // Give the target a beat to publish the new value before
                    // deciding the attribute was ignored.
                    do { try await Task.sleep(nanoseconds: 20_000_000) } catch {}
                }
                let after = Self.stringValue(of: target.element)
                if before == nil {
                    // Nothing to compare against; keep the legacy behaviour.
                    return InsertionResult(outcome: .successUnverified, method: "ax-selected-text")
                }
                if let before, let after, after != before {
                    return InsertionResult(outcome: .successUnverified, method: "ax-selected-text")
                }
                // Chromium-family web views report success for AXSelectedText
                // and change nothing. Fall through to typing rather than
                // claiming an insertion that never happened.
            }
            if status == .attributeUnsupported || status == .notImplemented { /* fall through */ }
            else if status == .noValue || status == .cannotComplete { return InsertionResult(outcome: .failed, method: "ax-selected-text", error: .axFailed) }
        }

        // Revalidate transaction and session before typing.
        if currentSessionGeneration() != sessionGeneration || !isTransactionActive() {
            return InsertionResult(outcome: .canceled, method: "none", error: .sessionChanged)
        }

        // Strategy B: typed input through the HID stream. Events posted
        // directly to a pid are dropped by Chromium's renderer, so the target is
        // activated and typing goes the same route as real keystrokes.
        guard let keyboardFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }
        if keyboardFrontmost != pid && keyboardFrontmost != ProcessInfo.processInfo.processIdentifier {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }
        target.app?.activate()
        if !(await Self.waitForActivation(pid: pid, deadline: Date().addingTimeInterval(0.6))) {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }

        // A right-click target carries its screen point: one click focuses the
        // field and puts the caret where the user opened the menu.
        if let point = target.clickPoint {
            Self.click(at: point)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        if !Self.isFocusedOrInside(target.element, pid: pid) {
            AXUIElementSetAttributeValue(
                target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        guard Self.isFocusedOrInside(target.element, pid: pid) else {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }

        return await Self.postUnicodeKeyboard(
            value, target: target.element, pid: pid,
            isTransactionActive: {
                currentSessionGeneration() == sessionGeneration && isTransactionActive()
            })
    }

    /// True when the element is the focused one or lives inside it. Web views
    /// often focus a child of the control that was hit-tested.
    @MainActor private static func isFocusedOrInside(_ element: AXUIElement, pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        var current: AXUIElement? = (focused as! AXUIElement)
        for _ in 0..<6 {
            guard let candidate = current else { return false }
            if CFEqual(candidate, element) { return true }
            var parentRef: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(
                    candidate, kAXParentAttribute as CFString, &parentRef) == .success,
                let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    @MainActor private static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point,
            mouseButton: .left)
        let up = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point,
            mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    @MainActor private static func postUnicodeKeyboard(
        _ text: String, target: AXUIElement, pid: pid_t,
        isTransactionActive: @escaping () -> Bool
    ) async -> InsertionResult {
        let source = CGEventSource(stateID: .hidSystemState)
        let chunks = UnicodeEventChunks.split(text)
        let before = stringValue(of: target)
        var insertedAny = false

        func focusUnchanged() -> Bool {
            FocusCapture.isProcessAlive(pid)
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && isFocusedOrInside(target, pid: pid)
        }

        if !focusUnchanged() {
            return InsertionResult(outcome: .canceled, method: "cg-keyboard", error: .focusChanged)
        }

        for (index, chunk) in chunks.enumerated() {
            // Cancel promptly without yielding a full chunk.
            if !isTransactionActive() {
                return InsertionResult(
                    outcome: insertedAny ? .partial : .canceled,
                    method: "cg-keyboard",
                    error: .sessionChanged
                )
            }
            // Revalidate the transaction target before each event chunk.
            if !focusUnchanged() {
                return InsertionResult(
                    outcome: insertedAny ? .partial : .canceled,
                    method: "cg-keyboard",
                    error: .focusChanged
                )
            }
            var chars = chunk
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                return InsertionResult(outcome: insertedAny ? .partial : .failed, method: "cg-keyboard", error: .keyboardFailed)
            }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.flags = []
            down.post(tap: .cghidEventTap)
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return InsertionResult(outcome: insertedAny ? .partial : .failed, method: "cg-keyboard", error: .keyboardFailed)
            }
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.flags = []
            up.post(tap: .cghidEventTap)
            insertedAny = true
            if index < chunks.count - 1 {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    return InsertionResult(outcome: .partial, method: "cg-keyboard", error: .sessionChanged)
                }
            }
        }

        // AX values can trail the insertion by a few frames; poll rather than
        // read once and risk reporting a false failure.
        if let before {
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                if let after = stringValue(of: target), after != before {
                    return InsertionResult(outcome: .successVerified, method: "cg-keyboard")
                }
            }
        }
        return InsertionResult(outcome: .successUnverified, method: "cg-keyboard")
    }
}
