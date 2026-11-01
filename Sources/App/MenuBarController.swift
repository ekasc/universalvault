import AppKit
import Combine
import Core

/// The menu bar icon. A click is the primary action (Quick Fill); the
/// management menu is on right-click, because a menu on left-click would
/// consume the click that is supposed to fill a field.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private weak var appState: AppState?
    private var stateObserver: AnyCancellable?

    func install(appState: AppState) {
        guard statusItem == nil else { return }
        self.appState = appState

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "lock", accessibilityDescription: "UniversalVault")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "UniversalVault — click to quick fill, right-click for the menu"
        }
        statusItem = item

        stateObserver = appState.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let unlocked = appState?.session.isUnlocked == true
        button.image = NSImage(
            systemSymbolName: unlocked ? "lock.open" : "lock",
            accessibilityDescription: "UniversalVault")
        button.image?.isTemplate = true
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // The icon manages the vault. Filling happens at the field with a
        // right-click, or from the global shortcut.
        showMenu()
    }

    // MARK: - Menu

    private func showMenu() {
        guard let statusItem else { return }
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let unlocked = appState?.session.isUnlocked == true
        let hasVault = appState?.session.existsVault() == true

        menu.addItem(item("Open Vault", #selector(openVault)))
        menu.addItem(
            item(
                unlocked ? "Lock Vault" : "Unlock Vault", #selector(toggleLock),
                enabled: hasVault))
        menu.addItem(.separator())

        let fill = item("Quick Fill", #selector(quickFill), enabled: unlocked)
        fill.keyEquivalent = "v"
        fill.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(fill)
        menu.addItem(.separator())

        menu.addItem(item("Welcome…", #selector(openWelcome)))
        menu.addItem(item("Settings…", #selector(openSettings), keyEquivalent: ","))

        if let error = appState?.errorMessage, !error.isEmpty {
            menu.addItem(.separator())
            let status = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())
        let quit = item("Quit UniversalVault", #selector(quitApplication), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func item(
        _ title: String, _ action: Selector, keyEquivalent: String = "", enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func openVault() {
        if let window = NSApp.windows.first(where: { $0.title == "Vault" && $0.canBecomeKey }) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // SwiftUI owns the window scene, and its open-window action is only
        // reachable through the scene itself. The File menu command calls that
        // action, so perform it from the menu bar instead of duplicating the
        // scene in AppKit.
        if performMainMenuItem(titled: "Open Vault") {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openWelcome() {
        if let window = NSApp.windows.first(where: { $0.title == "Welcome" && $0.canBecomeKey }) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        if performMainMenuItem(titled: "UniversalVault Help") {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    @objc private func toggleLock() {
        appState?.toggleLock()
    }

    @objc private func quickFill() {
        appState?.invokePalette(fromStatusItem: true)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @discardableResult
    private func performMainMenuItem(titled title: String) -> Bool {
        guard let mainMenu = NSApp.mainMenu,
            let match = findMenuItem(in: mainMenu, titled: title),
            let action = match.action
        else { return false }
        return NSApp.sendAction(action, to: match.target, from: match)
    }

    private func findMenuItem(in menu: NSMenu, titled title: String) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu,
                let found = findMenuItem(in: submenu, titled: title)
            {
                return found
            }
        }
        return nil
    }
}
