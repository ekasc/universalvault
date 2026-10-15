import SwiftUI
import Core
import VaultSecurity
import Insertion
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var autoLockMinutes: Int = 5
    @State private var requireAuthForSensitive: Bool = true
    @State private var showPreviews: Bool = false
    @State private var status: String?
    @State private var passphrase: String = ""
    @State private var showPassphrasePrompt = false
    @State private var pendingImportURL: URL?
    @State private var pendingExportURL: URL?
    @State private var pendingExport = false
    @State private var pendingImported: VaultPayload?
    @State private var showReplaceConfirmation = false

    private var payload: VaultPayload? { appState.session.currentPayload }

    var body: some View {
        Form {
            Section("General") {
                Stepper("Auto-lock after \(autoLockMinutes) min", value: $autoLockMinutes, in: 1...1440)
                Toggle("Require authentication for sensitive fields", isOn: $requireAuthForSensitive)
                Toggle("Show value previews", isOn: $showPreviews)
            }
            Section("Permissions") {
                Text(AccessibilityPermission.isTrusted() ? "Accessibility: granted" : "Accessibility: not granted")
                if !AccessibilityPermission.isTrusted() {
                    Button("Request Accessibility") { _ = AccessibilityPermission.requestPrompt() }
                }
            }
            Section("Backup") {
                Button("Export encrypted backup") { exportBackup() }
                Button("Import encrypted backup") { importBackup() }
            }
            if let status {
                Section { Text(status).foregroundStyle(.secondary).font(.caption) }
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear { load() }
        .onChange(of: autoLockMinutes) { _, _ in save() }
        .onChange(of: requireAuthForSensitive) { _, _ in save() }
        .onChange(of: showPreviews) { _, _ in save() }
        .alert("Passphrase", isPresented: $showPassphrasePrompt) {
            SecureField("Passphrase", text: $passphrase)
            Button("Cancel", role: .cancel) { pendingImportURL = nil; pendingExportURL = nil; pendingExport = false }
            Button("OK") { performPassphrase() }
        } message: {
            Text("Enter backup passphrase.")
        }
        .confirmationDialog("Replace vault contents with imported backup?", isPresented: $showReplaceConfirmation) {
            Button("Replace", role: .destructive) {
                if let imported = pendingImported {
                    Task {
                        do {
                            try await appState.session.mutate { p in
                                p.items = imported.items
                                p.categories = imported.categories
                                p.profiles = imported.profiles
                                p.settings = imported.settings
                            }
                            await MainActor.run { status = "Imported." }
                        } catch {
                            await MainActor.run { status = "Import failed: \\(error.localizedDescription)" }
                        }
                    }
                }
                pendingImported = nil
            }
            Button("Cancel", role: .cancel) { pendingImported = nil }
        }
    }

    private func load() {
        if let p = payload {
            autoLockMinutes = p.settings.autoLockMinutes
            requireAuthForSensitive = p.settings.requireAuthForSensitiveInsert
            showPreviews = p.settings.showValuePreviews
        }
    }

    private func save() {
        Task {
            do {
                try await appState.session.mutate { p in
                    p.settings.autoLockMinutes = autoLockMinutes
                    p.settings.requireAuthForSensitiveInsert = requireAuthForSensitive
                    p.settings.showValuePreviews = showPreviews
                }
                await MainActor.run { status = "Saved." }
            } catch {
                await MainActor.run { status = "Save failed: \\(error.localizedDescription)" }
            }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "UniversalVault-backup.uvbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingExportURL = url
        pendingExport = true
        passphrase = ""
        showPassphrasePrompt = true
    }

    private func performPassphrase() {
        if pendingExport, let url = pendingExportURL {
            pendingExport = false
            let p = passphrase
            Task {
                do {
                    let data = try appState.session.savePayloadToBackup(passphrase: p)
                    try data.write(to: url)
                    await MainActor.run { status = "Exported." }
                } catch {
                    await MainActor.run { status = "Export failed: \\(error.localizedDescription)" }
                }
            }
            pendingExportURL = nil
        } else if let url = pendingImportURL {
            let p = passphrase
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let imported = try VaultSession.importBackup(data, passphrase: p)
                    await MainActor.run {
                        pendingImported = imported
                        showReplaceConfirmation = true
                    }
                } catch {
                    await MainActor.run { status = "Import failed: \\(error.localizedDescription)" }
                }
            }
            pendingImportURL = nil
        }
        passphrase = ""
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
        passphrase = ""
        showPassphrasePrompt = true
    }

}
