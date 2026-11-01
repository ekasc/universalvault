import SwiftUI
import Core
import VaultSecurity

/// Milliseconds from app entry to each launch milestone, so a slow start is
/// measurable rather than described.
enum LaunchClock {
    nonisolated(unsafe) static var started = ProcessInfo.processInfo.systemUptime
    static func elapsedMilliseconds() -> Int {
        Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}

@main
struct UniversalVaultApp: App {
    @StateObject private var appState: AppState

    init() {
        LaunchClock.started = ProcessInfo.processInfo.systemUptime
        // The one non-UI entry point. It runs before any scene exists so an agent
        // can call the binary without opening a window or waiting on a prompt.
        if CommandLine.arguments.contains("--about-me") {
            exit(AboutMeCommand.run())
        }
        DispatchQueue.main.async { AppWindowRegistry.shared.updateActivationPolicy() }
        _appState = StateObject(wrappedValue: Self.makeAppState())
    }

    private static func makeAppState() -> AppState {
        do {
            if CommandLine.arguments.contains("--verify-native") || CommandLine.arguments.contains("--verify-insertion-target") {
#if DEBUG
                return try NativeVerification.makeAppState()
#else
                FileHandle.standardError.write(Data("Native verification is available only in debug builds.\n".utf8))
                exit(EXIT_FAILURE)
#endif
            }
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
        Window("Vault", id: "vault") {
            VaultWindowView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 560)
                .background(MainWindowBehavior(autosaveName: "Vault"))
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
        .commands { VaultCommands(appState: appState) }
        Settings {
            SettingsView()
                .environmentObject(appState)
                .background(MainWindowBehavior(autosaveName: "Settings"))
        }
        .defaultSize(width: 440, height: 520)
        Window("Welcome", id: "onboarding") {
            OnboardingView()
                .environmentObject(appState)
                .background(MainWindowBehavior(autosaveName: "Welcome"))
        }
        .defaultSize(width: 480, height: 460)
    }
}
