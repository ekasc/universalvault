import SwiftUI
import VaultSecurity

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Open Vault") { openWindow(id: "vault") }
            Button(appState.session.isUnlocked ? "Lock Vault" : "Unlock Vault") {
                if appState.session.isUnlocked {
                    appState.session.lock()
                } else {
                    Task { try? await appState.session.unlock() }
                }
            }
            Button("Settings…") { openWindow(id: "settings") }
            Divider()
            Text(appState.errorMessage ?? "").font(.caption).foregroundStyle(.red).lineLimit(2)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(8)
        .frame(width: 220)
        .onChange(of: appState.showPalette) { _, v in
            if v { openWindow(id: "palette") }
        }
    }
}
