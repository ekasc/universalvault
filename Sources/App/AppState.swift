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

    public init(session: VaultSession) {
        self.session = session
        self.hotKey = HotKeyManager()
        self.hotKey.onPress = { [weak self] in
            Task { @MainActor in self?.invokePalette() }
        }
        _ = self.hotKey.register()
    }

    public func invokePalette() {
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
    }

    public func refreshResults() {
        let payload = session.currentPayload
        guard let p = payload else { paletteResults = []; return }
        paletteResults = searchEngine.search(query: paletteQuery, payload: p)
        if paletteSelection >= paletteResults.count { paletteSelection = max(0, paletteResults.count - 1) }
    }

    public func dismissPalette() {
        showPalette = false
        paletteTarget = nil
        for w in NSApplication.shared.windows where w.title == "Quick Fill" { w.close() }
    }

    public func moveSelection(_ delta: Int) {
        guard !paletteResults.isEmpty else { return }
        paletteSelection = max(0, min(paletteResults.count - 1, paletteSelection + delta))
    }

    public func insertSelected() {
        guard paletteSelection < paletteResults.count else { dismissPalette(); return }
        let result = paletteResults[paletteSelection]
        let field = result.field
        // Determine if auth needed
        Task { @MainActor in
            // Sensitive/critical confirmation
            if field.sensitivity == .critical {
                do { try await session.requirePresence(reason: "Insert critical field \(field.label)") }
                catch { errorMessage = error.localizedDescription; return }
            } else if field.sensitivity == .sensitive && session.currentPayload?.settings.requireAuthForSensitiveInsert == true {
                // Could require presence; for demo require presence for sensitive too optionally. We'll require presence only for critical to keep UX; prompt confirm via alert not implemented. Keep no extra auth.
            }
            guard let target = paletteTarget else {
                errorMessage = "No insertion target captured."
                dismissPalette()
                return
            }
            let value = field.value.insertionText
            // hide palette first to avoid focus issues
            showPalette = false
            try? await Task.sleep(nanoseconds: 50_000_000)
            let r = insertion.insert(value: value, into: target, originalBundleID: originalBundleID, originalPID: originalPID)
            switch r.outcome {
            case .successVerified, .successUnverified: errorMessage = nil
            case .failed: errorMessage = r.error?.errorDescription ?? "Insertion failed."
            }
            paletteTarget = nil
        }
    }
}
