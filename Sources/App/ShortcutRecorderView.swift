import SwiftUI
import AppKit
import Core

/// Captures the next key chord the user presses and hands it to `onCapture`.
///
/// A local event monitor is used rather than `onKeyPress` because recording
/// needs the modifier flags and the raw virtual key code, and must swallow the
/// chord so it does not also act on the focused control.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var validationMessage: String?

    private var monitor: Any?
    private var onCapture: ((HotKeyShortcut) -> Void)?

    func start(onCapture: @escaping (HotKeyShortcut) -> Void) {
        stop()
        self.onCapture = onCapture
        validationMessage = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onCapture = nil
        isRecording = false
        // A successful capture also lands here, so clear any earlier complaint.
        validationMessage = nil
    }

    func cancel() {
        stop()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let keyCode = UInt32(event.keyCode)

        // Modifier keys themselves are not a shortcut.
        if ShortcutKey.modifierKeyCodes.contains(keyCode) { return nil }

        // Escape abandons recording instead of becoming the shortcut.
        if keyCode == 0x35 { cancel(); return nil }

        var modifiers: ShortcutModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        let shortcut = HotKeyShortcut(keyCode: keyCode, modifiers: modifiers)
        do {
            try shortcut.validate()
        } catch {
            validationMessage = error.localizedDescription
            return nil
        }

        let capture = onCapture
        stop()
        capture?(shortcut)
        return nil
    }
}

struct ShortcutRecorderView: View {
    let current: HotKeyShortcut
    let onCapture: (HotKeyShortcut) -> Void

    @StateObject private var model = ShortcutRecorderModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(current.displayString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    .accessibilityLabel("Current shortcut")
                    .accessibilityValue(current.displayString)
                Spacer()
                Button(model.isRecording ? "Cancel" : "Change") {
                    if model.isRecording {
                        model.cancel()
                    } else {
                        model.start(onCapture: onCapture)
                    }
                }
                .accessibilityHint("Records a new global shortcut. Press Escape to cancel.")
            }
            if let message = model.validationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if model.isRecording {
                Text("Press a chord with ⌘, ⌥ or ⌃. Escape cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { model.stop() }
    }
}
