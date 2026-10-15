import SwiftUI
import Core
import VaultSecurity

@main
struct UniversalVaultApp: App {
    @StateObject private var appState: AppState

    init() {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        _appState = StateObject(wrappedValue: Self.makeAppState())
    }

    private static func makeAppState() -> AppState {
        do {
            let storage = try FileSystemVaultStorage()
            let session = VaultSession(storage: storage, keyStore: KeychainVaultKeyStore(), auth: LocalAuthenticationService())
            return AppState(session: session)
        } catch {
            let alert = NSAlert()
            alert.messageText = "UniversalVault could not initialize secure storage."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        MenuBarExtra("Universal Vault", systemImage: "vault") {
            MenuBarView().environmentObject(appState)
        }
        Window("Vault", id: "vault") {
            VaultWindowView().environmentObject(appState)
        }
        .defaultSize(width: 900, height: 600)
        Window("Quick Fill", id: "palette") {
            PaletteView().environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 420)
                Window("Settings", id: "settings") {
            SettingsView().environmentObject(appState)
        }
        .defaultSize(width: 440, height: 520)
        Window("Onboarding", id: "onboarding") {
            OnboardingView().environmentObject(appState)
        }
        .defaultSize(width: 460, height: 320)
    }
}
