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
            fatalError("UniversalVault initialization failed: \(error.localizedDescription)")
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
        Window("Onboarding", id: "onboarding") {
            OnboardingView().environmentObject(appState)
        }
        .defaultSize(width: 460, height: 320)
    }
}
