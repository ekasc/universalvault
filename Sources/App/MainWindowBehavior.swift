import AppKit
import SwiftUI

struct MainWindowBehavior: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        WindowAttachment(autosaveName: autosaveName)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowAttachment: NSView {
        let autosaveName: String

        init(autosaveName: String) {
            self.autosaveName = autosaveName
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AppWindowRegistry.shared.register(window, autosaveName: autosaveName)
        }
    }
}

@MainActor
final class AppWindowRegistry {
    static let shared = AppWindowRegistry()
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    func register(_ window: NSWindow, autosaveName: String) {
        let id = ObjectIdentifier(window)
        guard closeObservers[id] == nil else { return }
        window.setFrameAutosaveName(autosaveName)
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.closeObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(observer)
                }
                self.updateActivationPolicy()
            }
        }
        updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = closeObservers.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}
