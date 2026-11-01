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

    @Published public var showPalette: Bool = false
    @Published public var paletteQuery: String = ""
    @Published public var paletteResults: [SearchResult] = []
    @Published public var paletteSelection: Int = 0
    @Published public var errorMessage: String?

    private var paletteTarget: TargetHandle?
    private var originalBundleID: String?
    private var originalPID: pid_t = 0
    private var activeOperationID: UUID?
    private var palettePanel: PalettePanelController?
    private let shortcutPreferences = ShortcutPreferences()
    private var cancellables = Set<AnyCancellable>()
    private var activityMonitor: Any?
    public var targetApplicationName: String? { paletteTarget?.app?.localizedName }

    public init(session: VaultSession, systemIntegration: Bool = true) {
        self.session = session
        self.hotKey = HotKeyManager()
        self.hotKey.onPress = { [weak self] in
            Task { @MainActor in self?.invokePalette() }
        }

        // `session` is a nested ObservableObject. Without this forwarding,
        // views that read `appState.session.isUnlocked` never re-render when
        // the vault is created, unlocked or locked.
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Sealing removes protected fields from the payload. The prepared search
        // index holds copies, so it must not outlive the seal, whether or not the
        // palette view happens to be mounted.
        session.$isSensitiveUnlocked
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.searchIndex = nil
                self.refreshResults()
            }
            .store(in: &cancellables)

        if systemIntegration {
            // The app opens the vault at launch; protected items still need
            // Touch ID. A first launch after upgrading from a presence-protected
            // key asks for it once and migrates.
            Task { [weak self, weak session] in
                Diagnostics.trace("launch: open dispatch after \(LaunchClock.elapsedMilliseconds())ms")
                await session?.openIfAvailable()
                let state = await MainActor.run { (session?.isUnlocked == true, session?.lastError) }
                await MainActor.run { self?.warmPalettePanel() }
                Diagnostics.trace(
                    "launch open: \(state.0 ? "vault open" : "vault locked") after \(LaunchClock.elapsedMilliseconds())ms \(state.1 ?? "")")
            }
            applyStoredShortcut()
            MenuBarController.shared.install(appState: self)
            RightClickFillController.shared.start(appState: self)
            activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { @Sendable [weak session] event in
                Task { @MainActor in
                    if session?.isUnlocked == true { session?.touch() }
                }
                return event
            }
        }
        session.onLock = { [weak self] in self?.clearSensitiveState() }
    }

    isolated deinit {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
    }

    private func applyStoredShortcut() {
        let stored = shortcutPreferences.load()
        if hotKey.register(stored) { return }
        if stored != .default, hotKey.register(.default) {
            shortcutPreferences.save(.default)
            errorMessage = "\(stored.displayString) is in use by another app; reverted to \(HotKeyShortcut.default.displayString)."
            return
        }
        errorMessage = "No global shortcut could be registered. Set one in Settings."
    }

    /// Attempts to register a new shortcut and persists it only on success.
    /// Returns a message describing the failure, or `nil` on success.
    public func updateShortcut(_ shortcut: HotKeyShortcut) -> String? {
        do { try shortcut.validate() } catch {
            return error.localizedDescription
        }
        // Re-registering the active chord would unregister it first, so a
        // transient failure would drop a working shortcut to report a false
        // conflict. There is nothing to do.
        if shortcut == hotKey.current && hotKey.isRegistered { return nil }

        let previous = hotKey.current
        if hotKey.register(shortcut) {
            shortcutPreferences.save(shortcut)
            return nil
        }
        guard hotKey.register(previous) else {
            return "\(shortcut.displayString) could not be registered and \(previous.displayString) could not be restored. No global shortcut is active."
        }
        return "\(shortcut.displayString) is already in use by another app; kept \(previous.displayString)."
    }

    public func toggleLock() {
        if session.isUnlocked {
            session.lock()
        } else {
            Task { @MainActor in
                do {
                    try await session.unlock()
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func clearSensitiveState() {
        searchIndex = nil
        paletteQuery = ""
        paletteResults = []
        paletteSelection = 0
        activeOperationID = nil
        paletteTarget = nil
        originalBundleID = nil
        originalPID = 0
        showPalette = false
        palettePanel?.hide()
    }

    /// Where the time went when the last Quick Fill opened. Read by the native
    /// performance gate; never used for behavior.
    public struct PaletteLatency: Sendable {
        public var capture: Double = 0
        public var search: Double = 0
        public var panel: Double = 0
        public var total: Double = 0
    }
    public private(set) var lastPaletteLatency: PaletteLatency?

    public func invokePalette(fromStatusItem: Bool = false) {
        let opened = DispatchTime.now().uptimeNanoseconds
        var latency = PaletteLatency()
        defer {
            latency.total = Double(DispatchTime.now().uptimeNanoseconds - opened) / 1_000_000
            lastPaletteLatency = latency
            Diagnostics.trace(
                "palette latency: capture=\(Int(latency.capture))ms search=\(Int(latency.search))ms panel=\(Int(latency.panel))ms total=\(Int(latency.total))ms")
        }
        activeOperationID = nil
        guard session.isUnlocked else {
            errorMessage = "Vault is locked."
            return
        }
        // The hotkey is a toggle. Re-entering while the palette is open used to
        // re-show the panel and hand first responder to the hosting view, which
        // left the search field unable to take typing until it was closed.
        if showPalette {
            dismissPalette()
            return
        }
        session.touch()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Clicking the status item can make this app active, so that path may
        // fall back to the last application that was frontmost before it.
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        let target = focusCapture.capture(allowLastExternal: fromStatusItem)
        latency.capture = Double(DispatchTime.now().uptimeNanoseconds - capturedAt) / 1_000_000
        if let target,
            target.app?.processIdentifier != ownPID
        {
            paletteTarget = target
            originalBundleID = target.app?.bundleIdentifier
            originalPID = target.app?.processIdentifier ?? 0
        } else {
            paletteTarget = nil
            originalBundleID = nil
            originalPID = 0
        }
        paletteQuery = ""
        let searchAt = DispatchTime.now().uptimeNanoseconds
        refreshResults()
        showPalette = true
        latency.search = Double(DispatchTime.now().uptimeNanoseconds - searchAt) / 1_000_000
        let front = NSWorkspace.shared.frontmostApplication
        Diagnostics.trace(
            "palette opened: front=\(front?.localizedName ?? "nil") target=\(self.paletteTarget?.app?.localizedName ?? "none") role=\(self.paletteTarget?.role ?? "none")"
        )
        warmPalettePanel()
        palettePanel?.show(restoring: paletteTarget?.app)
        latency.panel = palettePanel?.lastShowMilliseconds ?? 0
    }

    /// Prepared search state, rebuilt only when the vault version changes. Every
    /// keystroke in Quick Fill goes through here, so a stale or missing index is
    /// the difference between a frame and a stall.
    private var searchIndex: SearchIndex?

    public func refreshResults() {
        guard let payload = session.currentPayload else {
            searchIndex = nil
            paletteResults = []
            return
        }
        let index: SearchIndex
        if let cached = searchIndex, cached.updatedAt == payload.updatedAt,
            cached.lockedItemCount == payload.items.filter(\.isLocked).count
        {
            index = cached
        } else {
            index = SearchIndex(payload: payload)
            searchIndex = index
        }
        paletteResults = index.search(query: paletteQuery)
        if paletteSelection >= paletteResults.count { paletteSelection = max(0, paletteResults.count - 1) }
    }

    /// The palette is a SwiftUI hosting view; building it at launch cost more than
    /// opening the vault did. It is built on first use, and warmed once the vault
    /// is open so the first Control+Option+V is not the one that pays for it.
    private func warmPalettePanel() {
        guard palettePanel == nil else { return }
        palettePanel = PalettePanelController(appState: self)
    }

    public func dismissPalette() {
        showPalette = false
        activeOperationID = nil
        paletteTarget = nil
        palettePanel?.hide()
    }
    public func hidePaletteForAuthorizedInsertion() {
        showPalette = false
        palettePanel?.hide()
    }

    public func invalidateInsertionTransaction() {
        activeOperationID = nil
    }

    /// Applies a structural change to the vault and reports failure instead of
    /// dropping it. `VaultSession.mutate` runs to completion on the main actor,
    /// so concurrent calls from the UI cannot interleave their read and write.
    public func edit<Result>(actionName: String = "Vault Change", _ change: @escaping (inout VaultPayload) throws -> Result,
                              onSuccess: @escaping (Result) -> Void = { _ in }) {
        let generation = session.sessionGeneration
        Task { @MainActor in
            do {
                guard generation == session.sessionGeneration else { throw VaultEditError.staleConfirmation }
                let result = try await session.mutate(actionName: actionName, change)
                onSuccess(result)
            } catch {
                errorMessage = "Could not save: \(error.localizedDescription)"
            }
        }
    }

    public func restoreHistory(undo: Bool) async {
        do {
            if undo { try await session.undo() } else { try await session.redo() }
            refreshResults()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Fills one field into an element chosen by the right-click menu. Unlike
    /// the palette this has no query or selection state: the target element and
    /// the field are fixed when the menu opens, and the rules for protected
    /// fields are the same.
    public func fill(_ field: VaultField, of item: VaultItem, into target: TargetHandle) {
        guard session.isUnlocked, let payload = session.currentPayload,
            let authorization = InsertionAuthorization(
                itemID: item.id, fieldID: field.id, payload: payload,
                generation: session.sessionGeneration)
        else { return }
        let value = authorization.field.insertionText
        guard !value.isEmpty else {
            errorMessage = "That field is empty."
            return
        }
        let generation = session.sessionGeneration
        let transactionID = UUID()
        Diagnostics.trace("fill: role=\(target.role ?? "none") valueLen=\(value.count)")
        Task { @MainActor in
            do {
                if authorization.requiresPresence {
                    try await session.requirePresence(reason: "Insert a protected vault field")
                }
                guard generation == session.sessionGeneration,
                    authorization.isValid(
                        in: session.currentPayload, generation: session.sessionGeneration)
                else { return }
                let result = await insertion.insert(
                    value: value,
                    into: target,
                    originalBundleID: target.app?.bundleIdentifier,
                    originalPID: target.app?.processIdentifier ?? 0,
                    transactionID: transactionID,
                    sessionGeneration: generation,
                    currentSessionGeneration: { self.session.sessionGeneration },
                    isTransactionActive: { true }
                )
                Diagnostics.trace(
                    "right-click outcome: \(result.outcome.rawValue) method=\(result.method) error=\(result.error?.errorDescription ?? "none")"
                )
                switch result.outcome {
                case .successVerified, .successUnverified:
                    errorMessage = nil
                default:
                    errorMessage = result.error?.errorDescription ?? "Insertion failed."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func moveSelection(_ delta: Int) {
        guard !paletteResults.isEmpty else { return }
        paletteSelection = max(0, min(paletteResults.count - 1, paletteSelection + delta))
    }

    public func insertSelected() {
        guard paletteResults.indices.contains(paletteSelection) else { dismissPalette(); return }
        let result = paletteResults[paletteSelection]
        guard let payload = session.currentPayload,
              let authorization = InsertionAuthorization(itemID: result.item.id, fieldID: result.field.id,
                  payload: payload, generation: session.sessionGeneration),
              authorization.field == result.field else {
            refreshResults()
            errorMessage = "This field changed. Select it again before inserting."
            return
        }
        let field = authorization.field
        let operationID = UUID()
        activeOperationID = operationID
        let startingGeneration = session.sessionGeneration
        // Capture the transaction's context before any await can let a newer
        // operation replace shared selection state. Only this operation may
        // mutate the state it still owns.
        let capturedTarget = paletteTarget
        let capturedBundleID = originalBundleID
        let capturedPID = originalPID

        Task { @MainActor in
            if authorization.requiresPresence {
                do { try await session.requirePresence(reason: "Insert a protected vault field") }
                catch {
                    if self.activeOperationID == operationID {
                        self.errorMessage = error.localizedDescription
                        self.activeOperationID = nil
                    }
                    return
                }
            }

            if self.activeOperationID != operationID || !authorization.isValid(in: session.currentPayload, generation: session.sessionGeneration) {
                if self.activeOperationID == operationID {
                    self.errorMessage = "Insertion canceled."
                    self.activeOperationID = nil
                }
                return
            }

            guard let target = capturedTarget else {
                if self.activeOperationID == operationID {
                    Diagnostics.trace("insert aborted: no target")
                    // The palette footer already states why there is no target:
                    // either no field was focused or Accessibility access is off.
                    self.activeOperationID = nil
                }
                return
            }

            let value = field.insertionText
            if self.activeOperationID == operationID {
                self.hidePaletteForAuthorizedInsertion()
            }

            try? await Task.sleep(nanoseconds: 50_000_000)

            if self.activeOperationID != operationID || !authorization.isValid(in: session.currentPayload, generation: session.sessionGeneration) {
                if self.activeOperationID == operationID {
                    self.errorMessage = "Insertion canceled."
                    self.activeOperationID = nil
                }
                return
            }

            let r = await insertion.insert(
                value: value,
                into: target,
                originalBundleID: capturedBundleID,
                originalPID: capturedPID,
                transactionID: operationID,
                sessionGeneration: startingGeneration,
                currentSessionGeneration: { self.session.sessionGeneration },
                isTransactionActive: {
                    self.activeOperationID == operationID
                        && authorization.isValid(in: self.session.currentPayload, generation: self.session.sessionGeneration)
                }
            )
            let ownsTransaction = (self.activeOperationID == operationID)
            Diagnostics.trace(
                "insert outcome: \(r.outcome.rawValue) method=\(r.method) error=\(r.error?.errorDescription ?? "none")"
            )
            if ownsTransaction {
                switch r.outcome {
                case .successVerified, .successUnverified:
                    self.errorMessage = nil
                case .canceled, .rejected:
                    self.errorMessage = r.error?.errorDescription ?? "Insertion canceled."
                default:
                    self.errorMessage = r.error?.errorDescription ?? "Insertion failed."
                }
                self.activeOperationID = nil
            }
            if ownsTransaction {
                self.paletteTarget = nil
                self.originalBundleID = nil
                self.originalPID = 0
            }
        }
    }
}
