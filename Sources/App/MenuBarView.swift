import SwiftUI
import AppKit
import VaultSecurity

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var busy = false

    private var isUnlocked: Bool { appState.session.isUnlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(isUnlocked ? Color.green : Color.secondary)
                Text(isUnlocked ? "Vault unlocked" : "Vault locked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            Button("Quick Fill…") { appState.quickFillFromMenu() }
            if !appState.hotKey.isRegistered {
                Text("⌃⌥V shortcut unavailable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
            }
            Button(isUnlocked ? "Lock Vault" : "Unlock Vault") {
                if isUnlocked {
                    appState.dismissPalette()
                    appState.session.lock()
                } else {
                    busy = true
                    Task {
                        try? await appState.session.unlock()
                        busy = false
                    }
                }
            }
            .disabled(busy)
            Button("Open Vault") { openWindow(id: "vault") }
            Divider()
            if let error = appState.errorMessage ?? appState.session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Divider()
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(8)
        .frame(width: 220)
    }
}
