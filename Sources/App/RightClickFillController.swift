import AppKit
import ApplicationServices
import Core
import Insertion

/// Right-click in any editable field opens a menu of vault fields at the
/// cursor. macOS has no API to add items to another application's context menu,
/// so this intercepts the right-click, hit-tests the element underneath it, and
/// shows our own menu. Anything that is not an editable field, or any click
/// while the vault is locked, passes straight through to the application.
@MainActor
final class RightClickFillController {
    static let shared = RightClickFillController()

    private weak var appState: AppState?
    private var appStateRef: AppState?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: (any NSObjectProtocol)?
    private var swallowNextRightUp = false
    private var menuOpen = false

    private struct FillEntry {
        let item: VaultItem
        let field: VaultField
    }
    private var fillEntries: [FillEntry] = []
    private var target: TargetHandle?
    private var chosenTag: Int = 0

    private static let editKeyCode: [Int: CGKeyCode] = [
        10_001: CGKeyCode(7),  // Cut        (x)
        10_002: CGKeyCode(8),  // Copy       (c)
        10_003: CGKeyCode(9),  // Paste      (v)
        10_004: CGKeyCode(0),  // Select All (a)
    ]

    func start(appState: AppState) {
        self.appStateRef = appState
        self.appState = appState
        installIfNeeded()
        // The tap needs Accessibility trust, which can be granted after launch,
        // so retry whenever the user switches applications.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installIfNeeded() }
        }
    }

    private enum TapDecision { case pass, consume }

    private func installIfNeeded() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(
            (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue))
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let controller = Unmanaged<RightClickFillController>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    // The source runs on the main run loop, so this is the main
                    // thread. Only Sendable values cross into the closure.
                    let decision = MainActor.assumeIsolated {
                        controller.handle(
                            isDown: type == .rightMouseDown,
                            isUp: type == .rightMouseUp,
                            disabled: type == .tapDisabledByTimeout
                                || type == .tapDisabledByUserInput,
                            location: event.location)
                    }
                    return decision == .consume ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(isDown: Bool, isUp: Bool, disabled: Bool, location: CGPoint) -> TapDecision {
        if disabled {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return .pass
        }
        if isUp {
            if swallowNextRightUp {
                swallowNextRightUp = false
                return .consume
            }
            return .pass
        }
        guard isDown else { return .pass }
        guard !menuOpen, let appState,
            appState.session.isUnlocked, !appState.showPalette,
            let payload = appState.session.currentPayload
        else { return .pass }

        guard let target = appState.focusCapture.capture(at: location),
            let app = target.app,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return .pass }

        // A menu is built synchronously at the pointer. Building one item per
        // field is fine for a person's vault and pathological for a large one, so
        // the list is bounded and Quick Fill remains the way to search past it.
        let limit = 100
        var entries: [FillEntry] = []
        entries.reserveCapacity(limit)
        var truncated = false
        itemLoop: for item in payload.items.sorted(by: {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }) {
            for field in item.fields.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                if entries.count == limit {
                    truncated = true
                    break itemLoop
                }
                entries.append(FillEntry(item: item, field: field))
            }
        }

        swallowNextRightUp = true
        let appStateCopy = appState
        let capturedTarget = target
        DispatchQueue.main.async { [weak self] in
            self?.showMenu(
                entries: entries, truncated: truncated, target: capturedTarget,
                appState: appStateCopy)
        }
        return .consume
    }

    private func showMenu(
        entries: [FillEntry], truncated: Bool, target: TargetHandle, appState: AppState
    ) {
        guard !menuOpen else { return }
        menuOpen = true
        defer {
            menuOpen = false
            swallowNextRightUp = false
            fillEntries = []
        }
        self.appState = appState
        self.target = target
        fillEntries = entries
        chosenTag = 0

        let menu = NSMenu()
        menu.autoenablesItems = false

        if entries.isEmpty {
            let empty = NSMenuItem(title: "No fields yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, entry) in entries.enumerated() {
                let label = entry.field.label.isEmpty ? entry.field.key : entry.field.label
                let item = NSMenuItem(
                    title: "\(label) — \(entry.item.title)", action: #selector(choose(_:)),
                    keyEquivalent: "")
                item.tag = index + 1
                item.target = self
                item.image = NSImage(
                    systemSymbolName: icon(for: entry.field), accessibilityDescription: nil)
                menu.addItem(item)
            }
            if truncated {
                let more = NSMenuItem(
                    title: "More fields: press \(appState.hotKey.current.displayString)",
                    action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }
        }

        menu.addItem(.separator())
        addEditItem(menu, "Cut", tag: 10_001)
        addEditItem(menu, "Copy", tag: 10_002)
        addEditItem(menu, "Paste", tag: 10_003)
        addEditItem(menu, "Select All", tag: 10_004)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

        let choice = chosenTag
        chosenTag = 0
        guard choice > 0 else { return }
        if choice <= entries.count {
            let entry = entries[choice - 1]
            Diagnostics.trace(
                "right-click menu choice: field entries=\(entries.count)")
            appState.fill(entry.field, of: entry.item, into: target)
        } else if let keyCode = Self.editKeyCode[choice], let pid = target.app?.processIdentifier {
            sendCommand(keyCode, to: pid)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        chosenTag = sender.tag
    }

    private func addEditItem(_ menu: NSMenu, _ title: String, tag: Int) {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.tag = tag
        item.target = self
        menu.addItem(item)
    }

    /// Editing commands are forwarded as the real shortcut to the target app.
    /// UniversalVault never touches the pasteboard itself.
    private func sendCommand(_ keyCode: CGKeyCode, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = .maskCommand
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = .maskCommand
            up.postToPid(pid)
        }
    }

    private func icon(for field: VaultField) -> String {
        switch field.type {
        case .secret: return "lock"
        case .email: return "envelope"
        case .phone: return "phone"
        case .url: return "link"
        case .date: return "calendar"
        case .number: return "number"
        case .boolean: return "checkmark.square"
        case .multiline: return "text.alignleft"
        case .text, .custom: return "text.cursor"
        }
    }
}
