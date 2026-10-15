import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Universal Vault").font(.title2.bold())
            Text("Create an encrypted local vault protected by user presence (Touch ID/passcode).").multilineTextAlignment(.center)
            Button("Create Vault") {
                Task {
                    try? await appState.session.createNewVault()
                }
            }
            .buttonStyle(.borderedProminent)
            if let err = appState.session.lastError { Text(err).foregroundStyle(.red).font(.caption) }
        }
        .padding()
    }
}
