import Foundation
import SwiftUI
import Core
import VaultSecurity
import Insertion
import AppKit
import Combine

@MainActor
public final class AppState: ObservableObject {
    public let session: VaultSession
    public let hotKey: HotKeyManager
    public let focusCapture = FocusCapture()
    public let insertion = InsertionEngine()
    public let searchEngine = SearchEngine()

    @Published public var paletteQuery: String = ""
    @Published public var paletteResults: [SearchResult] = []
    @Published public var paletteSelection: Int = 0
    @Published public var paletteNotice: String?
    @Published public var isAuthenticating: Bool = false
    @Published public var errorMessage: String?
    @Published public var focusToken: Int = 0

    private var paletteTarget: TargetHandle?
    private var originalBundleID: String?
    private var originalPID: pid_t = 0
    private var palettePanel: PalettePanel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var lastExternalApp: NSRunningApplication?
    private var isInserting = false
    private var isWorking = false
    private var cancellables = Set<AnyCancellable>()

    public init(session: VaultSession) {
        self.session = session
        self.hotKey = HotKeyManager()
        self.hotKey.onPress = { [weak self] in
            Task { await self?.quickFill() }
        }
        _ = self.hotKey.register()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self?.remember(processID: pid) }
        }

        // Never leave decrypted results on screen if the vault locks underneath the palette.
        session.$isUnlocked
            .sink { [weak self] unlocked in
                guard !unlocked else { return }
                Task { @MainActor in self?.dismissPalette() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Entry point

    /// One keystroke: capture the field you are in, unlock if needed, show the palette.
    public func quickFill() async {
        guard !isInserting, !isAuthenticating, !isWorking else { return }
        if palettePanel?.isVisible == true {
            dismissPalette()
            return
        }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        // Capture the insertion target before anything can steal focus.
        var target = focusCapture.capture()
        if target == nil || target?.app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            target = await recaptureFromLastExternalApp()
        }
        paletteTarget = target
        originalBundleID = target?.app?.bundleIdentifier
        originalPID = target?.app?.processIdentifier ?? 0

        guard session.existsVault() else {
            await offerVaultCreation()
            return
        }

        if !session.isUnlocked {
            isAuthenticating = true
            NSApp.activate()
            do {
                try await session.unlock()
            } catch {
                isAuthenticating = false
                if !isCancellation(error) {
                    presentAlert("Could not unlock the vault", error.localizedDescription)
                }
                return
            }
            isAuthenticating = false
        }

        let notice: String?
        if paletteTarget == nil {
            notice = AccessibilityPermission.isTrusted()
                ? "No text field detected. Click into the field you want to fill, then press ⌃⌥V."
                : "Accessibility permission is required to fill fields in other apps."
        } else {
            notice = nil
        }
        presentPalette(notice: notice)
    }

    /// Called by the menu bar item. The menu makes this app frontmost, so the
    /// previously used app is re-activated before capture.
    public func quickFillFromMenu() {
        Task {
            // Let the menu bar window finish closing before refocusing the other app.
            try? await Task.sleep(for: .milliseconds(220))
            await quickFill()
        }
    }

    // MARK: - Palette state

    public func presentPalette(notice: String? = nil) {
        paletteQuery = ""
        paletteSelection = 0
        paletteNotice = notice
        refreshResults()
        ensurePanel()
        positionPanel(anchor: paletteTarget?.frame)
        installKeyMonitor()
        showPanel()
    }

    /// Shows the panel and guarantees it can actually receive keystrokes.
    /// The panel is non-activating, so it normally becomes key without stealing
    /// focus from the app being filled. If the window system refuses that, fall
    /// back to activating Universal Vault rather than showing a dead palette.
    private func showPanel() {
        palettePanel?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let panel = self.palettePanel, panel.isVisible, !panel.isKeyWindow {
                NSApp.activate()
                panel.makeKeyAndOrderFront(nil)
            }
            self.focusToken &+= 1
        }
    }

    public func queryChanged() {
        paletteSelection = 0
        refreshResults()
    }

    public func refreshResults() {
        guard let payload = session.currentPayload else {
            paletteResults = []
            return
        }
        paletteResults = searchEngine.search(query: paletteQuery, payload: payload)
        // On a password-style field, put secrets and sensitive values first so the
        // right entry is usually the first click.
        if paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           paletteTarget?.isSecureField == true {
            let secure = paletteResults.filter { $0.field.type == .secret || $0.field.sensitivity != .normal }
            let rest = paletteResults.filter { !($0.field.type == .secret || $0.field.sensitivity != .normal) }
            paletteResults = secure + rest
        }
        if paletteSelection >= paletteResults.count {
            paletteSelection = max(0, paletteResults.count - 1)
        }
    }

    public func dismissPalette() {
        removeKeyMonitor()
        palettePanel?.orderOut(nil)
        paletteTarget = nil
        paletteNotice = nil
        paletteQuery = ""
        paletteResults = []
    }

    public func moveSelection(_ delta: Int) {
        guard !paletteResults.isEmpty else { return }
        paletteSelection = max(0, min(paletteResults.count - 1, paletteSelection + delta))
    }

    // MARK: - Insertion

    public func insertSelected() {
        guard session.isUnlocked else {
            dismissPalette()
            return
        }
        guard paletteSelection >= 0, paletteSelection < paletteResults.count else {
            dismissPalette()
            return
        }
        let result = paletteResults[paletteSelection]
        let field = result.field
        guard let target = paletteTarget else {
            paletteNotice = AccessibilityPermission.isTrusted()
                ? "No text field detected. Click into the field you want to fill, then press ⌃⌥V."
                : "Accessibility permission is required to fill fields in other apps."
            return
        }
        guard !isInserting else { return }
        isInserting = true

        Task { @MainActor in
            defer { isInserting = false }

            if field.sensitivity == .critical {
                NSApp.activate()
                do {
                    try await session.requirePresence(reason: "Insert \(field.label)")
                } catch {
                    paletteNotice = isCancellation(error)
                        ? "Insertion canceled."
                        : "Authentication failed."
                    return
                }
            }

            // Get the palette out of the way, then give the target app its focus back.
            hidePaletteForInsertion()
            target.app?.activate()
            try? await Task.sleep(for: .milliseconds(140))

            // Pick up the field that actually holds focus now, if it is still the same app.
            var liveTarget = target
            if target.app != nil,
               let fresh = focusCapture.capture(),
               fresh.app?.processIdentifier == target.app?.processIdentifier {
                liveTarget = fresh
            }

            let value = field.value.insertionText
            let outcome = insertion.insert(
                value: value,
                into: liveTarget,
                originalBundleID: originalBundleID,
                originalPID: originalPID
            )

            switch outcome.outcome {
            case .successVerified, .successUnverified:
                paletteNotice = nil
                paletteTarget = nil
            case .failed:
                var message = outcome.error?.errorDescription ?? "Insertion failed."
                if outcome.error == .permissionDenied {
                    message += " Enable Universal Vault in System Settings → Privacy & Security → Accessibility."
                }
                paletteTarget = target
                paletteNotice = message
                showPanel()
                installKeyMonitor()
            }
        }
    }

    private func hidePaletteForInsertion() {
        removeKeyMonitor()
        palettePanel?.orderOut(nil)
    }

    // MARK: - Panel plumbing

    private func ensurePanel() {
        guard palettePanel == nil else { return }
        let size = NSSize(width: 420, height: 320)
        let panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.appState = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: PaletteView().environmentObject(self))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        palettePanel = panel
    }

    private func positionPanel(anchor: CGRect?) {
        guard let panel = palettePanel else { return }
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let fallback = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main

        // Anchor to the field when its rectangle is believable; otherwise fall back
        // to the classic centered palette.
        if let anchor,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? fallback,
           anchor.width < screen.visibleFrame.width * 0.8,
           anchor.height < 400 {
            let visible = screen.visibleFrame
            let gap: CGFloat = 6
            let below = anchor.minY - size.height - gap
            let above = anchor.maxY + gap

            var origin = CGPoint(x: anchor.minX, y: below)
            if below < visible.minY + 8, above + size.height <= visible.maxY - 8 {
                origin.y = above
            }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
            panel.setFrameOrigin(origin)
            return
        }

        guard let visible = fallback?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.maxY - size.height - 120).rounded()
        ))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case 53: // esc
                self.dismissPalette()
                return nil
            case 125: // down
                self.moveSelection(1)
                return nil
            case 126: // up
                self.moveSelection(-1)
                return nil
            default:
                return event
            }
        }

        // Clicking anywhere outside the palette dismisses it, like a menu.
        // Global monitors only see events destined for other apps, so clicks on
        // the palette itself never reach this.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isInserting, self.palettePanel?.isVisible == true else { return }
                self.dismissPalette()
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: - Target tracking

    private func remember(processID: pid_t) {
        guard processID != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: processID),
              app.activationPolicy == .regular else { return }
        lastExternalApp = app
    }

    private func recaptureFromLastExternalApp() async -> TargetHandle? {
        guard let app = lastExternalApp, !app.isTerminated else { return nil }
        app.activate()
        try? await Task.sleep(for: .milliseconds(180))
        let captured = focusCapture.capture()
        guard captured?.app?.processIdentifier == app.processIdentifier else { return nil }
        return captured
    }

    // MARK: - Errors

    private func isCancellation(_ error: Error) -> Bool {
        if let authError = error as? AuthError, case .canceled = authError { return true }
        if let keyStoreError = error as? KeyStoreError, case .accessDenied = keyStoreError { return true }
        return false
    }

    private func offerVaultCreation() async {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "No vault yet"
        alert.informativeText = "Create an encrypted vault first. It is protected by Touch ID or your Mac password."
        alert.addButton(withTitle: "Create Vault")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await session.createNewVault()
        } catch {
            presentAlert("Could not create the vault", error.localizedDescription)
        }
    }

    private func presentAlert(_ message: String, _ informative: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.runModal()
    }
}
