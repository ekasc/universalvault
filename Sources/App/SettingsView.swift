import AppKit
import Core
import Insertion
import SwiftUI
import VaultSecurity

struct SettingsView: View {
  @EnvironmentObject var appState: AppState
  @Environment(\.scenePhase) private var scenePhase
  @State private var settings = VaultSettings()
  @State private var loadedGeneration: UUID?
  @State private var saving = false
  @State private var saveTask: Task<Void, Never>?
  @State private var status: String?
  @State private var shortcut: HotKeyShortcut = .default
  @State private var accessibilityGranted = false
  @State private var transfer: BackupTransferMode?

  private var session: VaultSession { appState.session }

  var body: some View {
    Form {
      if !session.isUnlocked {
        Section {
          Text("Unlock the vault to change vault settings or export a backup.")
            .foregroundStyle(.secondary)
        }
      }
      Section("General") {
        Stepper(
          "Lock protected items after \(settings.autoLockMinutes) min",
          value: $settings.autoLockMinutes,
          in: AutoLock.minimumMinutes...AutoLock.maximumMinutes
        )
        .accessibilityLabel("Protected items lock timeout in minutes")
        .accessibilityIdentifier("settings.autoLock")
        Toggle(
          "Require authentication for sensitive fields",
          isOn: $settings.requireAuthForSensitiveInsert
        )
        .accessibilityLabel("Require authentication for sensitive fields")
        .accessibilityIdentifier("settings.requireAuthentication")
        Toggle("Show value previews", isOn: $settings.showValuePreviews)
          .accessibilityLabel("Show value previews")
          .accessibilityIdentifier("settings.previews")
        if saving { ProgressView("Saving settings…").controlSize(.small) }
      }
      .disabled(!session.isUnlocked || loadedGeneration != session.sessionGeneration || saving)
      Section("Global Shortcut") {
        ShortcutRecorderView(current: shortcut) { candidate in
          if let failure = appState.updateShortcut(candidate) {
            status = failure
          } else {
            shortcut = candidate
            status = "Shortcut set to \(candidate.displayString)."
          }
        }
      }
      Section("Permissions") {
        Text(accessibilityGranted ? "Accessibility: granted" : "Accessibility: not granted")
        if !accessibilityGranted {
          Button("Request Accessibility") {
            accessibilityGranted = AccessibilityPermission.requestPrompt()
          }
          Text("After granting access in System Settings, return here to refresh the status.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button("Refresh permission status") { refreshPermission() }
      }
      Section("Backup") {
        Button("Export encrypted backup…") { transfer = .export }
          .disabled(!session.isUnlocked)
          .accessibilityIdentifier("backup.export")
        Button("Restore encrypted backup…") {
          transfer = session.isUnlocked ? .replace : .recover
        }
        .accessibilityIdentifier("backup.restore")
      }
      if let status {
        Section { Text(status).textSelection(.enabled) }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 440, idealWidth: 500, minHeight: 460, idealHeight: 600)
    .onAppear {
      shortcut = appState.hotKey.current
      refreshPermission()
      load()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { refreshPermission() }
    }
    .onChange(of: session.sessionGeneration) { _, _ in
      saveTask?.cancel()
      saving = false
      status = nil
      load()
    }
    .onChange(of: session.currentPayload?.settings) { _, _ in
      if !saving { load() }
    }
    .onChange(of: settings) { _, updated in save(updated) }
    .onDisappear {
      saveTask?.cancel()
      saving = false
      loadedGeneration = nil
    }
    .sheet(item: $transfer) { mode in
      BackupTransferView(mode: mode).environmentObject(appState)
    }
  }

  private func refreshPermission() {
    accessibilityGranted = AccessibilityPermission.isTrusted()
  }

  private func load() {
    settings = session.currentPayload?.settings ?? VaultSettings()
    loadedGeneration = session.isUnlocked ? session.sessionGeneration : nil
  }

  private func save(_ snapshot: VaultSettings) {
    guard !saving, session.isUnlocked, loadedGeneration == session.sessionGeneration,
      snapshot != session.currentPayload?.settings
    else { return }
    let generation = session.sessionGeneration
    saving = true
    saveTask = Task { @MainActor in
      do {
        try Task.checkCancellation()
        try await session.mutate(actionName: "Change Settings") { payload in
          guard session.sessionGeneration == generation, session.isUnlocked else {
            throw VaultSessionError.supersededRequest
          }
          try Task.checkCancellation()
          payload.settings = snapshot
        }
        guard session.sessionGeneration == generation, !Task.isCancelled else { return }
        status = "Settings saved."
      } catch {
        guard session.sessionGeneration == generation, !Task.isCancelled else { return }
        status = "Settings could not be saved: \(error.localizedDescription)"
      }
      saving = false
      load()
    }
  }
}
