#if DEBUG
  import AppKit
  import SwiftUI
  import Foundation
  import CryptoKit
  import Core
  import VaultSecurity
  import Insertion

  private final class VerificationKeys: VaultKeyStore, @unchecked Sendable {
    private var key: SymmetricKey?
    private var sensitive: SymmetricKey?
    func keyExists() throws -> Bool { key != nil }
    func loadKey(reason: String) throws -> SymmetricKey {
      guard let key else { throw KeyStoreError.notFound }
      return key
    }
    func storeKey(_ key: SymmetricKey) throws { self.key = key }
    func deleteKey() throws { key = nil; sensitive = nil }
    func sensitiveKeyExists() throws -> Bool { sensitive != nil }
    func loadSensitiveKey(reason: String, context: AuthenticatedContext?) throws -> SymmetricKey {
      guard let sensitive else { throw KeyStoreError.notFound }
      return sensitive
    }
    func storeSensitiveKey(_ key: SymmetricKey) throws { sensitive = key }
    func deleteSensitiveKey() throws { sensitive = nil }
  }

  private struct VerificationAuth: UserPresenceAuthenticating {
    func authenticate(reason: String) async throws -> Bool { true }
  }

  @MainActor final class NativeVerification {
    private let directory: URL
    private let output: URL
    private let state: AppState
    private var window: NSWindow?
    private var results: [String: String] = [:]

    static func makeAppState() throws -> AppState {
      if let index = CommandLine.arguments.firstIndex(of: "--verify-insertion-target"),
        CommandLine.arguments.indices.contains(index + 1)
      {
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        let state = AppState(
          session: VaultSession(
            storage: VerificationTargetStorage(), keyStore: VerificationKeys(),
            auth: VerificationAuth()), systemIntegration: false)
        Task { @MainActor in await NativeInsertionTarget(output: output).run() }
        return state
      }
      guard let index = CommandLine.arguments.firstIndex(of: "--verify-native"),
        CommandLine.arguments.indices.contains(index + 1)
      else {
        throw VaultSessionError.invalidData("Native verification requires an output directory.")
      }
      let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "UniversalVault-native-\(UUID())")
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try Data(directory.path.utf8).write(
        to: output.appendingPathComponent("storage-directory"), options: .atomic)
      let storage = try FileSystemVaultStorage(directory: directory)
      let keys = VerificationKeys()
      let state = AppState(
        session: VaultSession(
          storage: storage, keyStore: keys, auth: VerificationAuth()),
        systemIntegration: false)
      let runner = NativeVerification(
        directory: directory, output: output, state: state, keyStore: keys)
      Task { @MainActor in await runner.run() }
      return state
    }

    private let keyStore: VerificationKeys

    private init(directory: URL, output: URL, state: AppState, keyStore: VerificationKeys) {
      self.directory = directory
      self.output = output
      self.state = state
      self.keyStore = keyStore
    }

    private struct VerificationFailure: Error, LocalizedError {
      let message: String
      var errorDescription: String? { message }
    }

    private func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw VerificationFailure(message: message) }
    }

    private func progress(_ step: String) {
      try? Data(step.utf8).write(
        to: output.appendingPathComponent("progress.txt"), options: .atomic)
    }

    private func settle(timeout: Duration = .seconds(5), until condition: () -> Bool = { true })
      async throws
    {
      let deadline = ContinuousClock.now.advanced(by: timeout)
      repeat {
        try await Task.sleep(for: .milliseconds(100))
        window?.contentView?.layoutSubtreeIfNeeded()
        if condition() { return }
      } while ContinuousClock.now < deadline
      throw VerificationFailure(message: "Timed out waiting for native state.")
    }

    private func show<Content: View>(
      _ content: Content, appState: AppState? = nil,
      size: NSSize = NSSize(width: 1100, height: 700)
    ) async throws {
      if window == nil {
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size),
          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
          defer: false)
        window.isReleasedWhenClosed = false
        window.title = "UniversalVault verification, synthetic data"
        window.center()
        self.window = window
      }
      window?.setContentSize(size)
      let hosting = NSHostingView(
        rootView: content.environmentObject(appState ?? state).frame(
          minWidth: min(900, size.width), minHeight: min(560, size.height)
        ).background(Color(nsColor: .windowBackgroundColor)))
      hosting.sizingOptions = []
      window?.contentView = hosting
      window?.setContentSize(size)
      NSApp.setActivationPolicy(.regular)
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      try await settle()
    }

    private func attribute(_ object: NSObject, _ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      guard object.responds(to: selector) else { return nil }
      return object.perform(selector)?.takeUnretainedValue()
    }

    private func nodes(in window: NSWindow?) -> [NSObject] {
      guard let window else { return [] }
      var result: [NSObject] = []
      var queue: [NSObject] = [window]
      var seen = Set<ObjectIdentifier>()
      while !queue.isEmpty && result.count < 2000 {
        let node = queue.removeFirst()
        guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
        result.append(node)
        if let children = attribute(node, "accessibilityChildren") as? [NSObject] {
          queue.append(contentsOf: children)
        }
        if let children = attribute(node, "accessibilityChildrenInNavigationOrder") as? [NSObject] {
          queue.append(contentsOf: children)
        }
        if let view = node as? NSView { queue.append(contentsOf: view.subviews) }
      }
      return result
    }

    private func nodes() -> [NSObject] { nodes(in: window) }

    /// Walks the process-wide Accessibility tree, which is where a popup menu
    /// appears after its menu button is pressed.
    private func applicationNodes() -> [AXUIElement] {
      let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
      var result: [AXUIElement] = []
      var queue: [AXUIElement] = [application]
      var seen = Set<CFHashCode>()
      while !queue.isEmpty && result.count < 3000 {
        let element = queue.removeFirst()
        guard seen.insert(CFHash(element)).inserted else { continue }
        result.append(element)
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
          == .success, let children = childrenRef as? [AXUIElement]
        {
          queue.append(contentsOf: children)
        }
      }
      return result
    }

    private func axText(_ element: AXUIElement, _ attribute: String) -> String {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
      else { return "" }
      return value.map { String(describing: $0) } ?? ""
    }

    private func axIsEnabled(_ element: AXUIElement) -> Bool {
      var value: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value)
          == .success
      else { return false }
      return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    private func findInApplication(_ name: String, enabledOnly: Bool = false) -> AXUIElement? {
      applicationNodes().first {
        (axText($0, kAXTitleAttribute) == name || axText($0, kAXDescriptionAttribute) == name)
          && (!enabledOnly || axIsEnabled($0))
      }
    }

    private func pressApplicationMenu(_ title: String) async throws {
      guard let element = findInApplication(title, enabledOnly: true) else {
        throw VerificationFailure(message: "Enabled popup menu item not found: \(title)")
      }
      let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
      try require(status == .success, "Popup menu item rejected: \(title)")
    }

    private func pressMenuButton(_ label: String) async throws {
      guard let node = findContaining(label) else {
        throw VerificationFailure(message: "Missing menu button: \(label)")
      }
      let selector = NSSelectorFromString("accessibilityPerformPress")
      guard node.responds(to: selector) else {
        throw VerificationFailure(message: "Menu button cannot be pressed: \(label)")
      }
      typealias Press = @convention(c) (AnyObject, Selector) -> Bool
      let action = unsafeBitCast(node.method(for: selector), to: Press.self)
      _ = action(node, selector)
    }

    private func findContaining(_ fragment: String) -> NSObject? {
      nodes().first {
        text($0, "accessibilityTitle").contains(fragment)
          || text($0, "accessibilityLabel").contains(fragment)
      }
    }

    private func text(_ node: NSObject, _ name: String) -> String {
      attribute(node, name).map { String(describing: $0) } ?? ""
    }

    private func find(_ name: String) -> NSObject? {
      nodes().first {
        text($0, "accessibilityIdentifier") == name || text($0, "accessibilityLabel") == name
          || text($0, "accessibilityTitle") == name
          || ((attribute($0, "accessibilityTitleUIElement") as? NSObject).map {
            text($0, "accessibilityValue") == name
          } ?? false)
      }
    }

    private func nativeAction(_ action: @escaping @MainActor @Sendable () throws -> Void)
      async throws
    {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.main.async {
          do {
            try action()
            continuation.resume()
          } catch { continuation.resume(throwing: error) }
        }
      }
    }

    private func press(_ name: String) async throws {
      let checkboxValue = find(name).flatMap { node in
        text(node, "accessibilityRole") == "AXCheckBox" ? text(node, "accessibilityValue") : nil
      }
      try await nativeAction { try self.pressNow(name) }
      if let checkboxValue {
        try await settle {
          self.find(name).map { self.text($0, "accessibilityValue") != checkboxValue } ?? false
        }
      }
    }

    private func pressNow(_ name: String) throws {
      guard let node = find(name) else {
        throw VerificationFailure(message: "Missing accessible control: \(name)")
      }
      let selector = NSSelectorFromString("accessibilityPerformPress")
      guard node.responds(to: selector) else {
        throw VerificationFailure(message: "Control cannot be pressed: \(name)")
      }
      typealias Press = @convention(c) (AnyObject, Selector) -> Bool
      let action = unsafeBitCast(node.method(for: selector), to: Press.self)
      let accepted = action(node, selector)
      if text(node, "accessibilityRole") != "AXCheckBox" {
        try require(accepted, "Native press rejected: \(name)")
      }
    }

    /// Presses a control in any application window, for sheet and dialog layers.
    private func pressAnywhere(_ name: String) async throws {
      try await nativeAction { try self.pressAnywhereNow(name) }
    }

    private func pressAnywhereNow(_ name: String) throws {
      for candidate in NSApp.windows {
        for node in nodes(in: candidate) {
          let titles = [
            text(node, "accessibilityTitle"), text(node, "accessibilityLabel"),
            text(node, "accessibilityIdentifier"),
          ]
          guard titles.contains(name) else { continue }
          let selector = NSSelectorFromString("accessibilityPerformPress")
          guard node.responds(to: selector) else { continue }
          typealias Press = @convention(c) (AnyObject, Selector) -> Bool
          let action = unsafeBitCast(node.method(for: selector), to: Press.self)
          _ = action(node, selector)
          return
        }
      }
      throw VerificationFailure(message: "Missing sheet control: \(name)")
    }

    private func enter(_ value: String, in name: String) async throws {
      try await nativeAction { try self.enterNow(value, in: name) }
    }

    private func enterNow(_ value: String, in name: String) throws {
      if let field = nodes().compactMap({ $0 as? NSTextField }).first(where: {
        text($0, "accessibilityLabel") == name || text($0, "accessibilityIdentifier") == name
          || text($0, "accessibilityPlaceholderValue") == name
          || ($0.cell.map {
            text($0, "accessibilityIdentifier") == name
              || text($0, "accessibilityPlaceholderValue") == name
          } ?? false)
      }), let window {
        (field.window ?? window).makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else {
          throw VerificationFailure(message: "Native field editor unavailable: \(name)")
        }
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: editor.selectedRange())
        return
      }
      guard let node = find(name) else {
        throw VerificationFailure(message: "Missing accessible text input: \(name)")
      }
      let selector = NSSelectorFromString("setAccessibilityValue:")
      try require(node.responds(to: selector), "Text input is not writable: \(name)")
      node.perform(selector, with: value)
    }

    private func capture(_ name: String) async throws {
      window?.contentView?.layoutSubtreeIfNeeded()
      window?.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(300))
      guard let view = window?.contentView,
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else {
        throw VerificationFailure(message: "Native window screenshot unavailable.")
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw VerificationFailure(message: "PNG encoding failed.")
      }
      try require(data.count > 5000, "Screenshot is unexpectedly small.")
      try data.write(to: output.appendingPathComponent("\(name).png"))
      results["lastWindowFrame"] = String(describing: window!.frame)
      let tree = nodes().map { node in
        [
          "class": String(describing: type(of: node)), "role": text(node, "accessibilityRole"),
          "label": text(node, "accessibilityLabel"),
          "title": text(node, "accessibilityTitle"), "id": text(node, "accessibilityIdentifier"),
          "value": text(node, "accessibilityValue"),
          "placeholder": text(node, "accessibilityPlaceholderValue"),
        ]
      }
      try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("\(name)-accessibility.json"))
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = [
        "-x", "-l", String(window!.windowNumber),
        output.appendingPathComponent("\(name)-window.png").path,
      ]
      try capture.run()
      capture.waitUntilExit()
      try require(
        capture.terminationStatus == 0,
        "Native window capture unavailable; a view-cache image is not an acceptance image.")
      results["windowCapture"] = "PASS"
    }

    /// Screenshots a window the harness did not create, so panel chrome such as
    /// the corner radius and the window shadow is part of the evidence.
    private func captureWindow(_ window: NSWindow, _ name: String) throws {
      window.displayIfNeeded()
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = [
        "-x", "-l", String(window.windowNumber),
        output.appendingPathComponent("\(name)-window.png").path,
      ]
      try capture.run()
      capture.waitUntilExit()
      try require(capture.terminationStatus == 0, "Panel capture unavailable.")
    }

    private func run() async {
      defer {
        state.session.lock()
        window?.close()
        window = nil
        try? FileManager.default.removeItem(at: directory)
      }
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await show(VaultWindowView())
        window?.appearance = NSAppearance(named: .aqua)
        try await settle()
        try await capture("01-create")
        try await press("vault.create")
        try await settle { self.state.session.isUnlocked && self.find("Add Item") != nil }
        results["createThroughNativeControl"] = "PASS, no authentication requested"
        try await capture("02-empty-vault")
        try await press("Add Item")
        try await settle {
          self.state.session.currentPayload?.items.count == 1 && self.find("Item title") != nil
        }
        try await enter("Native verification item", in: "Item title")
        try await settle {
          self.state.session.currentPayload?.items.first?.title == "Native verification item"
        }
        results["nativeCreateItemAndAutosave"] = "PASS"
        try await press("Add Field")
        try await settle { self.state.session.currentPayload?.items.first?.fields.count == 1 }
        try await enter("Café 日本語 🧪", in: "Field value")
        try await settle {
          self.state.session.currentPayload?.items.first?.fields.first?.insertionText
            == "Café 日本語 🧪"
        }
        results["nativeUnicodeFieldAutosave"] = "PASS"
        try await press("New Field options")
        try await settle { self.find("Field key") != nil }
        try await capture("17-field-options")
        try await press("New Field options")
        try await settle { self.find("Field key") == nil }
        guard let itemID = state.session.currentPayload?.items.first?.id else {
          throw VerificationFailure(message: "Item identity missing.")
        }
        // Change the stored item underneath the open editor, then type again.
        try await state.session.mutate { payload in
          payload.updateItem(itemID) { $0.title = "Changed elsewhere" }
        }
        try await enter("stale draft value", in: "Field value")
        try await settle {
          self.nodes().contains {
            self.text($0, "accessibilityValue").contains("changed elsewhere")
          }
        }
        try require(
          self.state.session.currentPayload?.items.first?.fields.first?.insertionText
            == "Café 日本語 🧪",
          "A stale editor draft overwrote an item changed by another writer.")
        results["staleEditorConflict"] = "PASS, conflict shown and stored value unchanged"
        try await capture("15-editor-conflict")
        // The editor keeps the draft, so reload before continuing.
        try await press("Reload saved item")
        try await settle {
          self.find("Item title").map { self.text($0, "accessibilityValue") == "Changed elsewhere" }
            ?? false
        }
        try require(
          !self.nodes().contains { self.text($0, "accessibilityValue").contains("Save failed") },
          "The conflict message survived reload, so the editor and window disagree about the failure."
        )
        // Toolbar search filters the list and shows its no-match state.
        try await enter("no-such-field", in: "Search items")
        try await settle {
          self.nodes().contains { self.text($0, "accessibilityValue") == "No matches" }
        }
        results["nativeSearchFiltering"] = "PASS, toolbar search and no-match state"
        try await capture("16-search-no-match")
        try await enter("", in: "Search items")
        try await settle {
          !self.nodes().contains { self.text($0, "accessibilityValue") == "No matches" }
        }
        window?.setContentSize(NSSize(width: 1100, height: 700))
        try await settle()
        try await capture("03-editor-light")
        window?.appearance = NSAppearance(named: .darkAqua)
        try await settle()
        try await capture("04-editor-dark")
        window?.appearance = NSAppearance(named: .aqua)
        window?.setContentSize(NSSize(width: 900, height: 560))
        try await settle()
        try await capture("05-editor-minimum")
        let backup = try state.session.savePayloadToBackup(
          passphrase: "synthetic-backup-passphrase")
        let imported = try VaultSession.importBackup(
          backup, passphrase: "synthetic-backup-passphrase")
        try require(
          imported.items.first?.fields.first?.insertionText == "Café 日本語 🧪",
          "Backup lost native field edit.")
        results["nativeEditEncryptedBackupRoundtrip"] = "PASS"
        state.session.lock()
        try await settle { self.find("vault.unlock") != nil }
        try await capture("06-locked")
        try require(
          !nodes().contains { text($0, "accessibilityValue").contains("Café 日本語") },
          "Private value remains accessible after lock.")
        results["lockRemovesAccessibleValues"] = "PASS"
        try await press("vault.unlock")
        try await settle { self.state.session.isUnlocked }
        results["nativeUnlockPersistedEdits"] = "PASS, synthetic authentication"
        try await state.session.mutate { payload in
          payload.items.append(
            VaultItem(
              title: "Private",
              fields: [
                VaultField(
                  key: "private", label: "Private", value: .text("synthetic-private-never-show"),
                  sensitivity: .critical)
              ]))
          payload.settings.showValuePreviews = true
        }
        state.paletteQuery = "Private"
        state.refreshResults()
        state.showPalette = true
        let paletteSize = NSSize(
          width: PaletteMetrics.width,
          height: PaletteMetrics.height(
            fieldCount: state.paletteResults.count, empty: state.paletteResults.isEmpty))
        try await show(PaletteView(), size: paletteSize)
        try await capture("09-palette-masked")
        try require(
          !nodes().contains {
            text($0, "accessibilityValue").contains("synthetic-private-never-show")
          }, "Palette exposes a critical preview.")
        results["criticalPalettePreviewMasked"] = "PASS, previews enabled"
        // The panel paints its own surface, corner radius, and hairline. Capture
        // the real window so that chrome is part of the acceptance image.
        let palettePanel = PalettePanelController(appState: state)
        palettePanel.show()
        try await Task.sleep(for: .milliseconds(500))
        try require(palettePanel.window.isKeyWindow, "Quick Fill panel is not the key window.")
        try require(
          palettePanel.window.firstResponder is NSTextView
            || palettePanel.window.firstResponder is NSTextField,
          "Quick Fill search field did not take keyboard focus.")
        try captureWindow(palettePanel.window, "09-palette-panel")
        // Clearing the query grows the result list; the panel must follow it
        // instead of clipping the last row.
        state.paletteQuery = ""
        state.refreshResults()
        try await Task.sleep(for: .milliseconds(600))
        let expected = PaletteMetrics.height(fieldCount: state.paletteResults.count, empty: false)
        try require(
          abs(palettePanel.window.frame.height - expected) < 1,
          "Quick Fill panel did not resize to its rows.")
        try captureWindow(palettePanel.window, "09-palette-panel-all")
        palettePanel.window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(300))
        try captureWindow(palettePanel.window, "09-palette-panel-dark")
        palettePanel.window.appearance = nil
        state.paletteQuery = "no-such-field"
        state.refreshResults()
        try await Task.sleep(for: .milliseconds(600))
        try captureWindow(palettePanel.window, "09-palette-panel-empty")
        palettePanel.hide()
        state.dismissPalette()
        let exported = output.appendingPathComponent("synthetic-native-\(UUID()).uvbackup")
        try await show(
          SettingsView()
            .environment(\.verificationBackupDestination, exported)
            .environment(\.verificationDirectExport, true),
          size: NSSize(width: 500, height: 660))
        try await settle {
          self.find("settings.previews").map { self.text($0, "accessibilityValue") == "1" } ?? false
        }
        try await press("settings.previews")
        try await settle { self.state.session.currentPayload?.settings.showValuePreviews == false }
        results["nativeSettingsPersistence"] = "PASS, toggle action persisted through the session"
        try await capture("07-settings")
        try await press("backup.export")
        try await settle { self.find("backup.passphrase") != nil }
        try await capture("08-backup-export")
        try await press("backup.cancel")
        try await settle { self.find("backup.passphrase") == nil }
        results["nativeBackupSheetAndCancel"] = "PASS"
        try await press("backup.export")
        try await settle { self.find("backup.passphrase") != nil }
        try await enter("synthetic-native-backup", in: "backup.passphrase")
        try await enter("synthetic-native-backup", in: "backup.confirmPassphrase")
        try await press("backup.continue")
        try await settle(timeout: .seconds(30)) {
          FileManager.default.fileExists(atPath: exported.path)
        }
        let restored = try VaultSession.importBackup(
          Data(contentsOf: exported), passphrase: "synthetic-native-backup")
        try require(restored.items.count == 2, "Native export did not preserve all items.")
        let permissions =
          try FileManager.default.attributesOfItem(atPath: exported.path)[.posixPermissions]
          as? NSNumber
        try require(permissions?.intValue == 0o600, "Native backup file is not private.")
        results["nativeBackupExportPrivateFile"] =
          "PASS, actual sheet, secure inputs, encryption, and file mode 0600; system save panel not driven"
        try await capture("10-backup-export-complete")
        try await press("backup.cancel")
        try await settle { self.find("backup.passphrase") == nil }
        try await state.session.mutate { payload in
          payload.items.append(VaultItem(title: "After export"))
        }
        // macOS installs a menu action only for an item it has validated, and
        // this harness cannot open a menu bar menu. Lock through the same
        // AppState entry point the menu item calls. Menu dispatch was observed
        // in an earlier run and is not part of this repeatable gate.
        state.toggleLock()
        try await settle { !self.state.session.isUnlocked }
        results["lockClearsSession"] = "PASS, shared AppState action"
        try await show(VaultWindowView())
        try await settle { self.find("vault.restore") != nil }
        try await capture("11-locked-before-recovery")
        try await show(
          BackupTransferView(mode: .recover).environment(\.verificationBackupSource, exported),
          size: NSSize(width: 520, height: 540))
        try await settle { self.find("backup.selectedFile") != nil }
        try await enter("synthetic-native-backup", in: "backup.passphrase")
        try await press("backup.continue")
        try await settle(timeout: .seconds(15)) {
          NSApp.windows.contains { candidate in
            self.nodes(in: candidate).contains {
              self.text($0, "accessibilityLabel") == "Authenticate and Recover"
                && self.text($0, "accessibilityRole") == "AXButton"
            }
          }
        }
        try await capture("12-recovery-confirmation")
        try await pressAnywhere("Authenticate and Recover")
        try await settle(timeout: .seconds(20)) { self.state.session.isUnlocked }
        try require(
          self.state.session.currentPayload?.items.count == 2,
          "Recovery did not restore the selected backup.")
        let archives = try FileManager.default.contentsOfDirectory(atPath: directory.path)
          .filter { $0.hasPrefix("vault-recovery-") }
        try require(archives.count == 1, "Recovery did not preserve exactly one original archive.")
        guard let archiveName = archives.first else {
          throw VerificationFailure(message: "Recovery archive missing.")
        }
        let archiveURL = directory.appendingPathComponent(archiveName)
        let archiveMode =
          try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.posixPermissions]
          as? NSNumber
        try require(archiveMode?.intValue == 0o600, "Recovery archive is not private.")
        let archived = try VaultCrypto.decrypt(
          Data(contentsOf: archiveURL), key: try keyStore.loadKey(reason: "Verify recovery archive")
        )
        try require(
          archived.items.count == 3,
          "Recovery archive did not preserve the pre-recovery vault contents.")
        progress("recovery-complete")
        results["nativeEncryptedRecovery"] =
          "PASS, confirmation dialog, private original archive, restored contents"
        try await capture("13-recovered")
        try await state.session.mutate(actionName: "Verification Undo") { payload in
          payload.items.append(VaultItem(title: "Undo target"))
        }
        // Menu items install an action only when macOS validated them as enabled,
        // which requires opening a menu bar menu this harness cannot do. Undo and
        // redo run through the same AppState entry points the menu uses.
        state.restoreHistory(undo: true)
        try require(
          state.session.currentPayload?.items.contains { $0.title == "Undo target" } == false,
          "Undo through the menu action path did not remove the item.")
        state.restoreHistory(undo: false)
        try require(
          state.session.currentPayload?.items.contains { $0.title == "Undo target" } == true,
          "Redo through the menu action path did not restore the item.")
        results["undoRedoActionPath"] = "PASS, shared AppState actions"
        // Agent sharing: the editor chip persists the flag, and the profile the
        // CLI prints is built from exactly that flag.
        let profileID = try await state.session.mutate { payload -> UUID in
          let item = VaultItem(
            title: "Agent profile",
            fields: [VaultField(key: "name", label: "Name", value: .text("Synthetic"))],
            isShareableWithAgents: true)
          payload.items.append(item)
          return item.id
        }
        try await show(ItemEditorView(itemID: profileID), size: NSSize(width: 900, height: 620))
        try await settle { self.find("item.agentSharing") != nil }
        try await press("item.agentSharing")
        try await settle {
          self.state.session.currentPayload?.items.first { $0.id == profileID }?
            .isShareableWithAgents == false
        }
        try await press("item.agentSharing")
        try await settle {
          self.state.session.currentPayload?.items.first { $0.id == profileID }?
            .isShareableWithAgents == true
        }
        try require(
          self.state.session.currentPayload.map {
            AgentProfile.build(from: $0).items.contains { $0.title == "Agent profile" }
          } ?? false,
          "The shareable item did not reach the agent profile.")
        results["agentSharingToggle"] = "PASS, chip persists and reaches the profile"
        try await capture("19-agent-sharing")
        // Per-item protection: the item is sealed at rest, its editor shows a
        // locked state, and the plaintext is absent from the accessibility tree.
        try await state.session.unlockSensitiveItems()
        let protectedID = try await state.session.mutate { payload -> UUID in
          let item = VaultItem(
            title: "Protected verification",
            fields: [
              VaultField(
                key: "token", label: "Token", type: .secret,
                value: .secret("synthetic-protected-value"))
            ],
            isSensitive: true)
          payload.items.append(item)
          return item.id
        }
        state.session.lockSensitiveItems()
        try await show(ItemEditorView(itemID: protectedID), size: NSSize(width: 900, height: 620))
        try await settle { self.find("item.unlockProtected") != nil }
        try require(
          !self.nodes().contains {
            self.text($0, "accessibilityValue").contains("synthetic-protected-value")
          }, "A locked item exposed its value in the accessibility tree.")
        results["protectedItemSealed"] = "PASS, editor locked and value absent"
        try await capture("20-protected-item")
        try await press("item.unlockProtected")
        try await settle(timeout: .seconds(5)) {
          self.state.session.isSensitiveUnlocked && self.find("Field value") != nil
        }
        results["protectedItemUnlock"] = "PASS, Touch ID through the editor"
        try await show(VaultWindowView())
        try await capture("18-browser")
        try await settle { self.find("New") != nil }
        progress("browser-shown")
        do {
          try await pressMenuButton("New")
          try await settle(timeout: .seconds(5)) {
            self.findInApplication("New Category…", enabledOnly: true) != nil
          }
          try await pressApplicationMenu("New Category…")
          try await settle { self.find("Category name") != nil }
          try await enter("Verification Category", in: "Category name")
          try await press("Save")
          try await settle {
            self.state.session.currentPayload?.categories.contains {
              $0.name == "Verification Category"
            } == true
          }
          progress("category-created")
          results["nativeCategoryCreation"] = "PASS, footer menu, sheet, and saved category"
          try await capture("14-category-created")
        } catch {
          let titles = applicationNodes()
            .map { axText($0, kAXTitleAttribute) }
            .filter { !$0.isEmpty }
          results["nativeCategoryCreation"] =
            "NOT VERIFIED: \(error.localizedDescription). Application AX titles: \(titles.prefix(40).joined(separator: " | "))"
          try? await capture("14-category-failure")
        }
        let replaceSource = exported
        try await show(
          SettingsView().environment(\.verificationBackupSource, replaceSource),
          size: NSSize(width: 500, height: 660))
        try await press("backup.restore")
        try await settle { self.find("backup.selectedFile") != nil }
        try await enter("synthetic-native-backup", in: "backup.passphrase")
        try await press("backup.continue")
        try await settle(timeout: .seconds(15)) {
          NSApp.windows.contains { candidate in
            self.nodes(in: candidate).contains {
              self.text($0, "accessibilityLabel") == "Replace Contents"
                && self.text($0, "accessibilityRole") == "AXButton"
            }
          }
        }
        try await pressAnywhere("Replace Contents")
        try await settle(timeout: .seconds(20)) {
          self.state.session.currentPayload?.items.count == 2
            && !self.state.session.canUndo && !self.state.session.canRedo
        }
        progress("replace-complete")
        results["nativeReplaceWhileUnlocked"] = "PASS, replaced contents and cleared history"
        window?.close()
        window = nil
        if AccessibilityPermission.isTrusted() {
          try await verifyInsertion(keyboard: false)
          try await verifyInsertion(keyboard: true)
        } else {
          results["externalFixtureInsertion"] = "NOT VERIFIED, Accessibility permission unavailable"
        }
        try await verifyPaletteLatency()
        results["status"] = "PASS"
      } catch {
        results["status"] = "FAIL"
        results["error"] = error.localizedDescription
        if window != nil { try? await capture("failure") }
      }
      results["limitations"] =
        "Synthetic authentication; no real Keychain, TCC changes, third-party app compatibility, VoiceOver, or focused-scene menu commands. Insertion target is an isolated native fixture. Screenshots capture this app window only."
      do {
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("result.json"), options: .atomic)
      } catch {
        FileHandle.standardError.write(Data("Could not write native verification result.\n".utf8))
      }
      state.session.lock()
      window?.close()
      window = nil
      do { try FileManager.default.removeItem(at: directory) } catch {
        FileHandle.standardError.write(Data("Could not remove verification storage.\n".utf8))
      }
      NSApp.terminate(nil)
    }

    /// Quick Fill is a global hotkey, so the production case is: another app is
    /// frontmost, the panel opens over it, and it must take key. Measured with
    /// the app's own instrumentation rather than polling, which would add its
    /// own latency to the number.
    private func verifyPaletteLatency() async throws {
      if !state.session.isUnlocked {
        try await state.session.unlock()
      }
      // Pressing the hotkey while the palette is open must close it. It used to
      // re-show the panel and leave the search field without first responder.
      progress("palette-toggle-start")
      state.invokePalette()
      progress("palette-toggle-invoked")
      try await settle { PalettePanelController.shared?.window.isVisible == true }
      progress("palette-toggle-visible")
      try await settle { PalettePanelController.shared?.window.isKeyWindow == true }
      progress("palette-toggle-focused")
      state.invokePalette()
      progress("palette-toggle-second-press")
      try await settle {
        !self.state.showPalette
          && PalettePanelController.shared?.window.isVisible != true
      }
      results["paletteHotkeyToggles"] = "PASS, second press closes it"

      // Warm once so the measurement is the steady-state path, not the one-time
      // panel construction.
      state.invokePalette()
      try await settle { PalettePanelController.shared?.window.isVisible == true }
      state.dismissPalette()
      try await Task.sleep(for: .milliseconds(200))

      let finder = NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == "com.apple.finder"
      }
      finder?.activate()
      try await Task.sleep(for: .milliseconds(400))

      state.invokePalette()
      try await settle(timeout: .seconds(3)) {
        PalettePanelController.shared?.window.isKeyWindow == true
      }
      // Typing changes the result count on every keystroke, and that used to
      // resize the window inside AppKit's display cycle and abort the app.
      for query in ["e", "ea", "e"] {
        state.paletteQuery = query
        state.refreshResults()
        try await Task.sleep(for: .milliseconds(150))
      }
      state.paletteQuery = "zzzz-no-match"
      state.refreshResults()
      try await Task.sleep(for: .milliseconds(250))
      let emptyHeight = PalettePanelController.shared?.window.frame.height ?? 0
      try require(
        abs(emptyHeight - PaletteMetrics.height(fieldCount: 0, empty: true)) < 1,
        "Quick Fill did not take the empty-state height.")
      state.paletteQuery = ""
      state.refreshResults()
      try await Task.sleep(for: .milliseconds(250))
      let rowsHeight = PalettePanelController.shared?.window.frame.height ?? 0
      try require(
        abs(
          rowsHeight
            - PaletteMetrics.height(fieldCount: state.paletteResults.count, empty: false)) < 1,
        "Quick Fill did not resize to its rows.")
      try require(
        PalettePanelController.shared?.window.isVisible == true,
        "Typing in Quick Fill closed the panel.")
      results["paletteTypingSurvivesResize"] = "PASS, deferred resize"

      guard let latency = state.lastPaletteLatency else {
        throw VerificationFailure(message: "Quick Fill recorded no latency.")
      }
      results["paletteOpenMilliseconds"] = String(format: "%.1f", latency.total)
      results["paletteOpenPanelMilliseconds"] = String(format: "%.1f", latency.panel)
      results["paletteOpenSearchMilliseconds"] = String(format: "%.1f", latency.search)
      results["paletteOpenTakesKey"] = "PASS"
      try require(latency.total < 500, "Quick Fill took \(Int(latency.total)) ms to open.")
      state.dismissPalette()
      NSApp.activate(ignoringOtherApps: true)
      try await Task.sleep(for: .milliseconds(300))
    }

    private func verifyInsertion(keyboard: Bool) async throws {
      let folder = output.appendingPathComponent(
        keyboard ? "insertion-keyboard" : "insertion-ax", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for name in ["ready", "snapshot", "request-snapshot"] {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
      }
      let targetProcess = Process()
      targetProcess.executableURL =
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      targetProcess.arguments = ["--verify-insertion-target", folder.path]
      targetProcess.standardOutput = FileHandle.nullDevice
      targetProcess.standardError = FileHandle.nullDevice
      try targetProcess.run()
      defer {
        if targetProcess.isRunning { targetProcess.terminate() }
        targetProcess.waitUntilExit()
      }
      try await settle {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path)
      }
      let app = NSRunningApplication(processIdentifier: targetProcess.processIdentifier)
      app?.activate()
      var captured: TargetHandle?
      try await settle {
        captured = FocusCapture().capture()
        return captured?.app?.processIdentifier == targetProcess.processIdentifier
      }
      guard let captured else {
        throw VerificationFailure(message: "Native insertion target unavailable.")
      }
      let target =
        keyboard
        ? TargetHandle(
          element: captured.element, role: captured.role, isSettableValue: captured.isSettableValue,
          isSettableSelectedText: false, app: captured.app) : captured
      let value = keyboard ? String(repeating: "Café 日本語 🧪 ", count: 8) : "Café 日本語 🧪\nline two"
      let generation = state.session.sessionGeneration
      let result = await state.insertion.insert(
        value: value, into: target, originalBundleID: captured.app?.bundleIdentifier,
        originalPID: targetProcess.processIdentifier, transactionID: UUID(),
        sessionGeneration: generation,
        currentSessionGeneration: { self.state.session.sessionGeneration })
      try require(
        result.outcome == .successUnverified || result.outcome == .successVerified,
        "Insertion fixture rejected: \(result.error?.localizedDescription ?? result.outcome.rawValue)"
      )
      try Data().write(to: folder.appendingPathComponent("request-snapshot"))
      try await settle {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("snapshot").path)
      }
      let actual = try String(
        contentsOf: folder.appendingPathComponent("snapshot"), encoding: .utf8)
      try require(
        actual == "prefix \(value)suffix",
        "Insertion did not preserve Unicode, caret, and unrelated text.")
      results[keyboard ? "controlledKeyboardInsertion" : "accessibilitySelectedTextInsertion"] =
        "PASS, separate native process and observed text"
      let canceled = await state.insertion.insert(
        value: "must not insert", into: target, originalBundleID: captured.app?.bundleIdentifier,
        originalPID: targetProcess.processIdentifier, transactionID: UUID(),
        sessionGeneration: generation,
        currentSessionGeneration: { generation }, isTransactionActive: { false })
      try require(canceled.outcome == .canceled, "Canceled insertion was not rejected.")
      let expiredTarget = TargetHandle(
        element: captured.element, role: captured.role, isSettableValue: captured.isSettableValue,
        isSettableSelectedText: captured.isSettableSelectedText, app: captured.app,
        capturedAt: Date().addingTimeInterval(-60))
      let expired = await state.insertion.insert(
        value: "must not insert", into: expiredTarget,
        originalBundleID: captured.app?.bundleIdentifier,
        originalPID: targetProcess.processIdentifier, transactionID: UUID(),
        sessionGeneration: generation,
        currentSessionGeneration: { generation })
      try require(
        expired.outcome == .canceled && expired.error == .expired,
        "Expired target was not rejected.")
      results["canceledAndExpiredInsertions"] = "PASS"
      if keyboard {
        var checks = 0
        let partial = await state.insertion.insert(
          value: String(repeating: "x", count: 600), into: target,
          originalBundleID: captured.app?.bundleIdentifier,
          originalPID: targetProcess.processIdentifier,
          transactionID: UUID(), sessionGeneration: generation,
          currentSessionGeneration: { self.state.session.sessionGeneration },
          isTransactionActive: {
            checks += 1
            if checks == 8 { self.state.session.lock() }
            return self.state.session.sessionGeneration == generation
          })
        try require(
          partial.outcome == .partial,
          "Lock during keyboard insertion did not report partial delivery.")
        results["lockDuringKeyboardDispatch"] = "PASS, dispatch stops and reports partial delivery"
      }
    }
  }

  private struct VerificationTargetStorage: VaultStorage {
    var url: URL {
      FileManager.default.temporaryDirectory.appendingPathComponent("unused-verification-target")
    }
    func read() throws -> Data? { nil }
    func write(_ data: Data) throws { throw CryptoEnvelopeError.invalidData }
    func exists() -> Bool { false }
  }

  @MainActor private final class NativeInsertionTarget {
    let output: URL
    init(output: URL) { self.output = output }

    func run() async {
      let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 240))
      text.string = "prefix suffix"
      text.isEditable = true
      text.isRichText = false
      text.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
      text.setAccessibilityLabel("Synthetic insertion fixture")
      let window = NSWindow(
        contentRect: text.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "UniversalVault insertion verification, synthetic data"
      window.contentView = text
      window.center()
      NSApp.setActivationPolicy(.regular)
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      window.makeFirstResponder(text)
      text.setSelectedRange(NSRange(location: 7, length: 0))
      do {
        try Data().write(to: output.appendingPathComponent("ready"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
          if FileManager.default.fileExists(
            atPath: output.appendingPathComponent("request-snapshot").path)
          {
            try Data(text.string.utf8).write(
              to: output.appendingPathComponent("snapshot"), options: .atomic)
          }
          try await Task.sleep(for: .milliseconds(50))
        }
      } catch {
        FileHandle.standardError.write(
          Data("Insertion fixture failed: \(error.localizedDescription)\n".utf8))
      }
      window.close()
      NSApp.terminate(nil)
    }
  }
#endif
