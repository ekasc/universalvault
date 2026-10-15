import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

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

    @MainActor private static func waitForActivation(pid: pid_t, deadline: Date) -> Bool {
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
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
        currentSessionGeneration: () -> UUID,
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

        // Validate focus and role before insertion
        var focusedRef: CFTypeRef?
        let axApp = AXUIElementCreateApplication(pid)
        let copyStatus = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard copyStatus == .success, let focused = focusedRef else {
            return InsertionResult(outcome: .rejected, method: "none", error: .targetInvalid)
        }
        let focusedElement = focused as! AXUIElement
        guard CFEqual(target.element, focusedElement) else {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }
        if target.role == nil { /* continue */ }

        // Capability checks
        if target.role?.lowercased().contains("text") == false && target.role != "AXTextArea" && target.role != "AXTextField" {
            // allow unknown roles to avoid over-blocking but mark unverified if used
        }
        if !(target.isSettableSelectedText || target.isSettableValue) {
            return InsertionResult(outcome: .rejected, method: "none", error: .readOnly)
        }

        // Strategy A: AX selected text
        if target.isSettableSelectedText {
            let status = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, value as CFTypeRef)
            if status == .success {
                return InsertionResult(outcome: .successUnverified, method: "ax-selected-text")
            }
            if status == .attributeUnsupported || status == .notImplemented { /* fall through */ }
            else if status == .noValue || status == .cannotComplete { return InsertionResult(outcome: .failed, method: "ax-selected-text", error: .axFailed) }
        }

        // Revalidate transaction and session before keyboard fallback
        if currentSessionGeneration() != sessionGeneration || !isTransactionActive() {
            return InsertionResult(outcome: .canceled, method: "none", error: .sessionChanged)
        }

        // Strategy B: synthetic keyboard (controlled fallback)
        if let app = target.app {
            app.activate()
        }
        // Bounded, event-driven activation verification instead of arbitrary sleep.
        if !Self.waitForActivation(pid: pid, deadline: Date().addingTimeInterval(0.5)) {
            return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
        }

        // Final validation of focused element
        var focusedRef2: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef2)
        if let f2 = focusedRef2 as! AXUIElement? {
            if !CFEqual(target.element, f2) {
                return InsertionResult(outcome: .canceled, method: "none", error: .focusChanged)
            }
        } else {
            return InsertionResult(outcome: .canceled, method: "none", error: .targetInvalid)
        }

        return await Self.postUnicodeKeyboard(value, target: target.element, pid: pid, axApp: axApp, isTransactionActive: isTransactionActive)
    }

    @MainActor private static func postUnicodeKeyboard(_ text: String, target: AXUIElement, pid: pid_t, axApp: AXUIElement, isTransactionActive: @escaping () -> Bool) async -> InsertionResult {
        let source = CGEventSource(stateID: .hidSystemState)
        let chunkSize = 20
        var index = text.startIndex
        var insertedAny = false

        func focusUnchanged() -> Bool {
            guard FocusCapture.isProcessAlive(pid) else { return false }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return false }
            var focusedRef: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            guard status == .success, let focused = focusedRef else { return false }
            return CFEqual((focused as! AXUIElement), target)
        }

        if !focusUnchanged() {
            return InsertionResult(outcome: .canceled, method: "cg-keyboard", error: .focusChanged)
        }

        while index < text.endIndex {
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
                    error: insertedAny ? .focusChanged : .focusChanged
                )
            }
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])
            index = end
            var chars = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                return InsertionResult(outcome: insertedAny ? .partial : .failed, method: "cg-keyboard", error: .keyboardFailed)
            }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.postToPid(pid)
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return InsertionResult(outcome: insertedAny ? .partial : .failed, method: "cg-keyboard", error: .keyboardFailed)
            }
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.postToPid(pid)
            insertedAny = true
            if index < text.endIndex {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    return InsertionResult(outcome: .partial, method: "cg-keyboard", error: .sessionChanged)
                }
            }
        }
        return InsertionResult(outcome: .successUnverified, method: "cg-keyboard")
    }
}
