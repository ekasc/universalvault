import Foundation
import SwiftUI
import Core
import VaultSecurity
import Insertion
import AppKit

@MainActor
public final class AppState: ObservableObject {
    public let session: VaultSession
    public let hotKey: HotKeyManager
    public let focusCapture = FocusCapture()
    public let insertion = InsertionEngine()
    public let searchEngine = SearchEngine()

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

    public init(session: VaultSession) {
        self.session = session
        self.hotKey = HotKeyManager()
        self.hotKey.onPress = { [weak self] in
            Task { @MainActor in self?.invokePalette() }
        }
        _ = self.hotKey.register()
        let panel = PalettePanelController(appState: self)
        self.palettePanel = panel
        session.onLock = { [weak self] in self?.clearSensitiveState() }
    }

    public func clearSensitiveState() {
        paletteQuery = ""
        paletteResults = []
        paletteSelection = 0
        activeOperationID = nil
        paletteTarget = nil
        originalBundleID = nil
        originalPID = 0
        showPalette = false
        PalettePanelController.shared?.hide()
        for w in NSApplication.shared.windows where w.title == "Quick Fill" { w.close() }
    }

    public func invokePalette() {
        activeOperationID = nil
        guard session.isUnlocked else {
            errorMessage = "Vault is locked."
            return
        }
        if let t = focusCapture.capture() {
            paletteTarget = t
            originalBundleID = t.app?.bundleIdentifier
            originalPID = t.app?.processIdentifier ?? 0
        } else {
            paletteTarget = nil
            originalBundleID = nil
            originalPID = 0
        }
        paletteQuery = ""
        refreshResults()
        showPalette = true
        PalettePanelController.shared?.show()
    }

    public func refreshResults() {
        let payload = session.currentPayload
        guard let p = payload else { paletteResults = []; return }
        paletteResults = searchEngine.search(query: paletteQuery, payload: p)
        if paletteSelection >= paletteResults.count { paletteSelection = max(0, paletteResults.count - 1) }
    }

    public func dismissPalette() {
        showPalette = false
        activeOperationID = nil
        paletteTarget = nil
        PalettePanelController.shared?.hide()
        for w in NSApplication.shared.windows where w.title == "Quick Fill" { w.close() }
    }
    public func hidePaletteForAuthorizedInsertion() {
        showPalette = false
        PalettePanelController.shared?.hide()
        for w in NSApplication.shared.windows where w.title == "Quick Fill" { w.close() }
    }

    public func invalidateInsertionTransaction() {
        activeOperationID = nil
    }

    public func moveSelection(_ delta: Int) {
        guard !paletteResults.isEmpty else { return }
        paletteSelection = max(0, min(paletteResults.count - 1, paletteSelection + delta))
    }

    public func insertSelected() {
        guard paletteSelection < paletteResults.count else { dismissPalette(); return }
        let result = paletteResults[paletteSelection]
        let field = result.field
        let operationID = UUID()
        activeOperationID = operationID
        let startingGeneration = session.sessionGeneration

        Task { @MainActor in
            if field.sensitivity == .critical {
                do { try await session.requirePresence(reason: "Insert critical field \(field.label)") }
                catch {
                    if activeOperationID == operationID { errorMessage = error.localizedDescription }
                    activeOperationID = nil
                    return
                }
            } else if field.sensitivity == .sensitive && (session.currentPayload?.settings.requireAuthForSensitiveInsert ?? true) {
                do { try await session.requirePresence(reason: "Insert sensitive field \(field.label)") }
                catch {
                    if activeOperationID == operationID { errorMessage = error.localizedDescription }
                    activeOperationID = nil
                    return
                }
            }

            if activeOperationID != operationID || !session.isUnlocked || session.sessionGeneration != startingGeneration {
                activeOperationID = nil
                errorMessage = "Insertion canceled."
                return
            }

            guard let target = paletteTarget else {
                if activeOperationID == operationID { errorMessage = "No insertion target captured." }
                dismissPalette()
                activeOperationID = nil
                return
            }

            let value = field.insertionText
            hidePaletteForAuthorizedInsertion()

            try? await Task.sleep(nanoseconds: 50_000_000)

            if activeOperationID != operationID || !session.isUnlocked || session.sessionGeneration != startingGeneration {
                errorMessage = "Insertion canceled."
                activeOperationID = nil
                return
            }

            let r = await insertion.insert(
                value: value,
                into: target,
                originalBundleID: originalBundleID,
                originalPID: originalPID,
                transactionID: operationID,
                sessionGeneration: startingGeneration,
                currentSessionGeneration: { self.session.sessionGeneration },
                isTransactionActive: { self.activeOperationID == operationID }
            )
            if activeOperationID == operationID {
                switch r.outcome {
                case .successVerified, .successUnverified:
                    errorMessage = nil
                case .canceled, .rejected:
                    errorMessage = r.error?.errorDescription ?? "Insertion canceled."
                default:
                    errorMessage = r.error?.errorDescription ?? "Insertion failed."
                }
                activeOperationID = nil
            }
            paletteTarget = nil
            originalBundleID = nil
            originalPID = 0
        }
    }
}
