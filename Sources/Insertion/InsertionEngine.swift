import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

public enum InsertionOutcome: String, Sendable {
    case successVerified
    case successUnverified
    case failed
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

    public func insert(value: String, into target: TargetHandle, originalBundleID: String?, originalPID: pid_t) -> InsertionResult {
        guard !value.isEmpty else { return InsertionResult(outcome: .failed, method: "none", error: .valueEmpty) }
        if !AccessibilityPermission.isTrusted() { return InsertionResult(outcome: .failed, method: "none", error: .permissionDenied) }

        // Validate process alive
        if !FocusCapture.isProcessAlive(target.app?.processIdentifier ?? originalPID) {
            return InsertionResult(outcome: .failed, method: "none", error: .targetClosed)
        }

        // Strategy A: AX selected text
        if target.isSettableSelectedText {
            let status = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, value as CFTypeRef)
            if status == .success {
                return InsertionResult(outcome: .successUnverified, method: "ax-selected-text")
            }
        }

        // Strategy B: synthetic keyboard events to pid
        // Activate target app briefly? Instead post to pid
        target.app?.activate()
        Thread.sleep(forTimeInterval: 0.1)
        let ok = Self.postUnicode(value, to: target.app?.processIdentifier ?? originalPID)
        if ok { return InsertionResult(outcome: .successUnverified, method: "cg-keyboard") }

        return InsertionResult(outcome: .failed, method: "none", error: .keyboardFailed)
    }

    private static func postUnicode(_ text: String, to pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        // Post in chunks to avoid quartz limits
        let chunkSize = 20
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])
            index = end
            var chars = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return false }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.postToPid(pid)
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.postToPid(pid)
            // small pacing
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
