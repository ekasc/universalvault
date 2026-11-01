import AppKit
import Core
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import VaultSecurity

enum BackupTransferMode: String, Identifiable {
  case export, replace, recover
  var id: String { rawValue }
}

#if DEBUG
  private struct VerificationBackupDestinationKey: EnvironmentKey {
    static let defaultValue: URL? = nil
  }
  private struct VerificationBackupSourceKey: EnvironmentKey {
    static let defaultValue: URL? = nil
  }
  private struct VerificationDirectExportKey: EnvironmentKey {
    static let defaultValue = false
  }
  extension EnvironmentValues {
    var verificationBackupDestination: URL? {
      get { self[VerificationBackupDestinationKey.self] }
      set { self[VerificationBackupDestinationKey.self] = newValue }
    }
    var verificationBackupSource: URL? {
      get { self[VerificationBackupSourceKey.self] }
      set { self[VerificationBackupSourceKey.self] = newValue }
    }
    var verificationDirectExport: Bool {
      get { self[VerificationDirectExportKey.self] }
      set { self[VerificationDirectExportKey.self] = newValue }
    }
  }
#endif

struct BackupTransferView: View {
  let mode: BackupTransferMode
  @EnvironmentObject var appState: AppState
  @Environment(\.dismiss) private var dismiss
  #if DEBUG
    @Environment(\.verificationBackupDestination) private var verificationBackupDestination
    @Environment(\.verificationBackupSource) private var verificationBackupSource
    @Environment(\.verificationDirectExport) private var verificationDirectExport
  #endif
  @FocusState private var passphraseFocused: Bool
  @State private var passphrase = ""
  @State private var confirmation = ""
  @State private var sourceURL: URL?
  @State private var showImporter = false
  @State private var imported: VaultPayload?
  @State private var importedGeneration: UUID?
  @State private var showConfirmation = false
  @State private var busy = false
  @State private var completed = false
  @State private var status: String?
  @State private var task: Task<Void, Never>?
  @State private var operationID = UUID()
  @State private var panel: NSSavePanel?
  @State private var pickerGeneration: UUID?

  private var session: VaultSession { appState.session }
  private var exporting: Bool { mode == .export }
  private var validSession: Bool { mode == .recover ? !session.isUnlocked : session.isUnlocked }
  private var title: String { exporting ? "Export encrypted backup" : "Restore encrypted backup" }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.title2)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(explanation).foregroundStyle(.secondary)
          if !completed {
            if !exporting {
              Button("Choose encrypted backup…") {
                pickerGeneration = session.sessionGeneration
                showImporter = true
              }
              .accessibilityIdentifier("backup.chooseFile")
              if let sourceURL {
                Text(sourceURL.lastPathComponent).lineLimit(2)
                  .accessibilityIdentifier("backup.selectedFile")
              }
            }
            SecureField(
              exporting ? "New backup passphrase" : "Backup passphrase", text: $passphrase
            )
            .focused($passphraseFocused)
            .accessibilityIdentifier("backup.passphrase")
            if exporting {
              SecureField("Confirm backup passphrase", text: $confirmation)
                .accessibilityIdentifier("backup.confirmPassphrase")
              Text(
                "Use at least 12 characters. Keep the passphrase separately; it cannot be recovered."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          }
          if busy {
            ProgressView(
              exporting
                ? "Encrypting backup…"
                : (imported == nil ? "Reading encrypted backup…" : "Restoring vault…"))
          }
          if let status {
            Text(status).textSelection(.enabled)
              .accessibilityIdentifier("backup.status")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(busy || panel != nil)
      }
      HStack {
        Spacer()
        Button(completed ? "Done" : "Cancel") {
          cancel()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("backup.cancel")
        if !completed {
          Button(exporting ? "Export…" : "Read backup") {
            if exporting { chooseDestination() } else { readBackup() }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(
            busy || panel != nil || !validSession || passphrase.isEmpty
              || (!exporting && sourceURL == nil)
          )
          .accessibilityIdentifier("backup.continue")
        }
      }
    }
    .padding(24)
    .frame(minWidth: 440, idealWidth: 500, minHeight: 360, idealHeight: 440)
    .onAppear {
      passphraseFocused = true
      #if DEBUG
        if !exporting, sourceURL == nil, let verificationBackupSource {
          sourceURL = verificationBackupSource
        }
      #endif
    }
    .onDisappear { cancel() }
    .onChange(of: session.sessionGeneration) { _, _ in
      invalidate()
      if !completed {
        status = "The vault session changed. Choose the backup and enter its passphrase again."
      }
    }
    .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
      guard pickerGeneration == session.sessionGeneration, validSession else { return }
      switch result {
      case .success(let url):
        sourceURL = url
        status = nil
      case .failure(let error):
        if (error as NSError).code == NSUserCancelledError {
          clearSecrets()
          sourceURL = nil
        } else {
          status = "Could not open backup: \(error.localizedDescription)"
        }
      }
    }
    .confirmationDialog(
      mode == .recover ? "Recover vault from this backup?" : "Replace vault contents?",
      isPresented: $showConfirmation, titleVisibility: .visible
    ) {
      // Recovery keeps the previous encrypted file, so it is not destructive.
      if mode == .recover {
        Button("Authenticate and Recover") { restore() }
          .accessibilityIdentifier("backup.confirmRestore")
      } else {
        Button("Replace Contents", role: .destructive) { restore() }
          .accessibilityIdentifier("backup.confirmRestore")
      }
      Button("Cancel", role: .cancel) { clearSecrets() }
    } message: {
      if let imported {
        Text(
          "This backup contains \(imported.items.count) items, \(imported.categories.count) categories, and \(imported.profiles.count) profiles. \(mode == .recover ? "The existing encrypted vault file, if present, will be preserved in a separate recovery archive before replacement. Recovery requires system authentication." : "All current items, categories, profiles, and vault settings will be replaced. This cannot be undone. Export a backup first if you need the current contents.")"
        )
      }
    }
    .onChange(of: showConfirmation) { _, showing in
      if !showing && !busy { clearSecrets() }
    }
  }

  private var explanation: String {
    switch mode {
    case .export:
      return
        "The backup contains all vault contents and settings, encrypted with a separate passphrase."
    case .replace:
      return "Read an encrypted backup, then review its counts before replacing the unlocked vault."
    case .recover:
      return
        "Recover a locked or missing vault using an encrypted backup. Any existing encrypted vault file is preserved in a recovery archive, not silently overwritten. Your Mac will ask you to authenticate."
    }
  }

  private func isCurrent(_ id: UUID, _ generation: UUID) -> Bool {
    operationID == id && session.sessionGeneration == generation && validSession
      && !Task.isCancelled
  }

  private func chooseDestination() {
    guard validSession, !busy, panel == nil else { return }
    guard passphrase.count >= 12 else {
      status = "Use a passphrase of at least 12 characters."
      return
    }
    guard passphrase == confirmation else {
      status = "The passphrases do not match."
      return
    }
    let generation = session.sessionGeneration
    let id = UUID()
    operationID = id
    #if DEBUG
      // The system save panel runs in a separate service that an automated
      // harness cannot drive. Verification exports to its staged destination.
      if verificationDirectExport, let destination = verificationBackupDestination {
        export(to: destination, id: id, generation: generation)
        return
      }
    #endif
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = "UniversalVault-backup.uvbackup"
    #if DEBUG
      if let destination = verificationBackupDestination {
        savePanel.directoryURL = destination.deletingLastPathComponent()
        savePanel.nameFieldStringValue = destination.lastPathComponent
      }
    #endif
    savePanel.canCreateDirectories = true
    guard let parent = NSApp.keyWindow else {
      status = "Open a vault window before exporting a backup."
      return
    }
    panel = savePanel
    savePanel.beginSheetModal(for: parent) { @Sendable response in
      Task { @MainActor in
        guard isCurrent(id, generation) else { return }
        panel = nil
        guard response == .OK, let url = savePanel.url else {
          clearSecrets()
          return
        }
        guard
          url.resolvingSymlinksInPath().standardizedFileURL
            != session.storageURL.resolvingSymlinksInPath().standardizedFileURL
        else {
          status =
            "Choose a different destination. A backup cannot overwrite the active vault file."
          return
        }
        export(to: url, id: id, generation: generation)
      }
    }
  }

  private func export(to url: URL, id: UUID, generation: UUID) {
    guard isCurrent(id, generation), let payload = session.currentPayload else { return }
    let password = passphrase
    busy = true
    status = nil
    task = Task { @MainActor in
      do {
        guard isCurrent(id, generation) else { return }
        let worker = Task.detached(priority: .userInitiated) {
          try Task.checkCancellation()
          let data = try VaultSession.exportBackup(payload, passphrase: password)
          try Task.checkCancellation()
          return data
        }
        let data = try await withTaskCancellationHandler(
          operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard isCurrent(id, generation) else { return }
        // No suspension between the generation check and the file commit.
        try Self.writePrivateBackup(data, to: url)
        clearSecrets()
        completed = true
        status = "Backup exported to \(url.path)."
      } catch {
        guard isCurrent(id, generation) else { return }
        status = "Export failed: \(error.localizedDescription)"
      }
      busy = false
    }
  }

  private func readBackup() {
    guard !busy, validSession, let url = sourceURL else { return }
    let generation = session.sessionGeneration
    let id = UUID()
    operationID = id
    let password = passphrase
    busy = true
    status = nil
    task = Task { @MainActor in
      do {
        guard isCurrent(id, generation) else { return }
        let worker = Task.detached(priority: .userInitiated) {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          try Task.checkCancellation()
          let handle = try FileHandle(forReadingFrom: url)
          defer { try? handle.close() }
          let limit = VaultSession.maximumBackupSize
          let data = try handle.read(upToCount: limit + 1) ?? Data()
          guard data.count <= limit else {
            throw VaultSessionError.invalidData("Backup exceeds the 64 MiB limit.")
          }
          try Task.checkCancellation()
          let payload = try VaultSession.importBackup(data, passphrase: password)
          try Task.checkCancellation()
          return payload
        }
        let payload = try await withTaskCancellationHandler(
          operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard isCurrent(id, generation) else { return }
        imported = payload
        importedGeneration = generation
        showConfirmation = true
      } catch {
        guard isCurrent(id, generation) else { return }
        status = "Could not read backup: \(error.localizedDescription)"
      }
      busy = false
    }
  }

  private func restore() {
    guard !busy, validSession, let payload = imported,
      let generation = importedGeneration, generation == session.sessionGeneration
    else {
      clearSecrets()
      return
    }
    let id = UUID()
    operationID = id
    busy = true
    task = Task { @MainActor in
      do {
        guard isCurrent(id, generation) else { return }
        let archive: URL?
        if mode == .recover {
          archive = try await session.recoverContents(with: payload)
        } else {
          try await session.replaceContents(with: payload)
          archive = nil
        }
        guard operationID == id, !Task.isCancelled else { return }
        clearSecrets()
        completed = true
        status =
          archive.map { "Vault recovered. Original encrypted file preserved at \($0.path)." }
          ?? "Backup restored successfully."
      } catch {
        guard isCurrent(id, generation) else { return }
        imported = nil
        importedGeneration = nil
        status = "Restore failed: \(error.localizedDescription)"
      }
      busy = false
    }
  }

  private func clearSecrets() {
    passphrase = ""
    confirmation = ""
    imported = nil
    importedGeneration = nil
  }

  private func invalidate() {
    operationID = UUID()
    task?.cancel()
    task = nil
    panel?.cancel(nil)
    panel = nil
    showImporter = false
    pickerGeneration = nil
    showConfirmation = false
    sourceURL = nil
    clearSecrets()
    busy = false
  }

  private func cancel() { invalidate() }

  static func writePrivateBackup(_ data: Data, to url: URL) throws {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".uvbackup-\(UUID().uuidString)")
    let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = Darwin.unlink(temporary.path) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    guard Darwin.rename(temporary.path, url.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
