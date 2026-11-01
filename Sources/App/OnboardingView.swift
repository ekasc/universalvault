import AppKit
import Core
import Insertion
import SwiftUI
import VaultSecurity

/// First-run and reference window. Reachable from the menu bar and from the
/// vault window's empty state, so it is not dead code.
struct OnboardingView: View {
  @EnvironmentObject var appState: AppState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow

  @State private var trusted = AccessibilityPermission.isTrusted()
  @State private var creating = false
  @State private var status: String?

  private var session: VaultSession { appState.session }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "lock.square.stack")
          .font(.system(size: 34, weight: .light))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text("Universal Vault").font(.title2.bold())
          Text("Local, encrypted storage for the details you retype.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        bullet(
          "externaldrive", "Everything stays on this Mac, encrypted with a key in your Keychain.")
        bullet(
          "touchid",
          "Items you mark protected ask for Touch ID or your password before their fields are read.")
        bullet(
          "lock.shield",
          "Sleeping or locking the screen seals protected items only. Signing out or quitting closes the whole vault.")
        bullet(
          "lock.square",
          "Locking the screen seals protected items. Signing out or quitting closes the whole vault."
        )
        bullet(
          "keyboard",
          "\(appState.hotKey.current.displayString) opens quick fill over whatever you are typing in."
        )
      }

      Divider()

      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 2) {
          Text(trusted ? "Accessibility: granted" : "Accessibility: not granted")
          Text("Required to type into other applications.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        Spacer()
        if !trusted {
          Button("Request…") {
            _ = AccessibilityPermission.requestPrompt()
            trusted = AccessibilityPermission.isTrusted()
          }
          .accessibilityHint("Opens the system permission prompt.")
        }
      }

      Divider()

      if let error = status ?? session.lastError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if creating {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Creating vault…").font(.callout)
          Spacer()
        }
      }

      HStack {
        Spacer()
        Button("Close") { dismiss() }
          .keyboardShortcut(creating ? nil : .cancelAction)
        if session.existsVault() {
          Button("Open Vault") {
            openWindow(id: "vault")
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        } else {
          Button("Create Vault", action: create)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(creating)
            .accessibilityIdentifier("onboarding.create")
        }
      }
    }
    .padding(24)
    .frame(width: 480)
    .onAppear { trusted = AccessibilityPermission.isTrusted() }
  }

  /// Creation no longer authenticates, so there is nothing to cancel and no
  /// progress worth showing for longer than a frame.
  private func create() {
    guard !creating else { return }
    creating = true
    status = nil
    Task { @MainActor in
      do {
        try await session.createNewVault()
        status = nil
      } catch {
        status = error.localizedDescription
      }
      creating = false
    }
  }

  private func bullet(_ symbol: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .frame(width: 18)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(text).font(.callout)
    }
    .accessibilityElement(children: .combine)
  }
}
