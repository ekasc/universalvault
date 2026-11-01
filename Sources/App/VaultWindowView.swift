import SwiftUI
import Core
import VaultSecurity
import AppKit

/// Shell for the vault window: it owns the create/locked states and hands the
/// unlocked case to the browser.
struct VaultWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var authenticationTask: Task<Void, Never>?
    @State private var authenticationID = UUID()
    @State private var authenticating = false
    @State private var showRecovery = false
    @State private var status: String?

    private var session: VaultSession { appState.session }

    var body: some View {
        Group {
            if !session.existsVault() {
                lockedState(creating: true)
            } else if !session.isUnlocked {
                lockedState(creating: false)
            } else {
                VaultBrowserView()
            }
        }
        .navigationTitle("Vault")
        .safeAreaInset(edge: .bottom) {
            if let error = appState.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss") { appState.errorMessage = nil }
                }
                .padding(12)
                .background(.background)
                .accessibilityElement(children: .contain)
            }
        }
        .sheet(isPresented: $showRecovery) {
            BackupTransferView(mode: .recover).environmentObject(appState)
        }
        .onDisappear { cancelAuthentication() }
        .onChange(of: session.sessionGeneration) { _, _ in
            authenticationTask?.cancel()
            authenticationID = UUID()
            authenticating = false
            status = nil
        }
    }

    private func lockedState(creating: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: creating ? "lock.square.stack" : "lock.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            Text(creating ? "No vault yet" : "Vault locked")
                .font(Typography.recordTitle)
                .foregroundStyle(Theme.primary)
            if creating {
                Text("Everything stays on this Mac, encrypted with a key held in your Keychain.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let error = status ?? session.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("vault.authenticationError")
            }
            if authenticating {
                ProgressView(creating ? "Creating vault…" : "Unlocking vault…")
                    .controlSize(.small)
                    .accessibilityIdentifier("vault.authenticationProgress")
                Button("Cancel") { cancelAuthentication(); status = "Authentication cancelled." }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("vault.cancelAuthentication")
            }
            Button(creating ? "Create Vault" : "Unlock") { authenticate(creating: creating) }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(authenticating)
                .accessibilityIdentifier(creating ? "vault.create" : "vault.unlock")
                .padding(.top, 4)
            Button("Restore encrypted backup…") { showRecovery = true }
                .disabled(authenticating)
                .accessibilityIdentifier("vault.restore")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private func authenticate(creating: Bool) {
        guard !authenticating else { return }
        let generation = session.sessionGeneration
        let id = UUID()
        authenticationID = id
        authenticating = true
        status = nil
        authenticationTask = Task { @MainActor in
            do {
                guard generation == session.sessionGeneration, !Task.isCancelled else { return }
                if creating { try await session.createNewVault() } else { try await session.unlock() }
            } catch {
                guard authenticationID == id, generation == session.sessionGeneration, !Task.isCancelled else { return }
                status = error.localizedDescription
            }
            guard authenticationID == id else { return }
            authenticating = false
            authenticationTask = nil
        }
    }

    private func cancelAuthentication() {
        guard authenticating else { return }
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticationID = UUID()
        authenticating = false
    }
}

private struct VaultBrowserView: View {
    @EnvironmentObject var appState: AppState

    /// Optional because `List(selection:)` binds to an optional. Defaults to
    /// All Items so the sidebar highlight matches what the list shows; `nil` is
    /// read as All Items everywhere else.
    @State private var selection: VaultSelection? = .allItems
    @State private var selectedItemID: UUID?
    @SceneStorage("vaultSidebarVisible") private var sidebarVisible = true

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 == .all || $0 == .automatic })
    }

    private var payload: VaultPayload? { appState.session.currentPayload }
    private var activeSelection: VaultSelection { selection ?? .allItems }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            ItemListView(selection: $selection, selectedItemID: $selectedItemID)
                .navigationSplitViewColumnWidth(min: 240, ideal: 285, max: 380)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 380, ideal: 640)
        }
        .onChange(of: selection) { _, newValue in
            if !isValidScope(newValue) { selection = .allItems }
            reconcileSelectedItem()
        }
        .onChange(of: payload?.updatedAt) { _, _ in
            // A backup import can replace every category and profile; a scope
            // pointing at one that no longer exists has to land somewhere the
            // list can actually show.
            if !isValidScope(selection) { selection = .allItems }
            reconcileSelectedItem()
        }
        .onChange(of: appState.session.isUnlocked) { _, unlocked in
            if !unlocked { selectedItemID = nil }
        }
    }

    /// `nil` is what clicking empty sidebar space produces; treating it as
    /// All Items keeps the highlight and the list contents agreeing.
    private func isValidScope(_ candidate: VaultSelection?) -> Bool {
        guard let candidate else { return false }
        switch candidate {
        case .allItems:
            return true
        case .category(let id):
            return payload?.categories.contains { $0.id == id } ?? false
        case .profile(let id):
            return payload?.profiles.contains { $0.id == id } ?? false
        }
    }

    /// The previously selected item may not be in the new scope; leaving it
    /// selected would edit an item the list is no longer showing.
    private func reconcileSelectedItem() {
        guard let payload, let id = selectedItemID else { return }
        if VaultBrowser.items(payload.items, selection: activeSelection).contains(where: { $0.id == id }) { return }
        selectedItemID = nil
    }

    @ViewBuilder
    private var detail: some View {
        if payload?.items.isEmpty == true {
            // The list already says there is nothing; a second empty state in
            // the detail pane is noise.
            Color.clear
        } else if let id = selectedItemID, payload?.items.contains(where: { $0.id == id }) == true {
            // `.id` forces a fresh editor per item. Without it SwiftUI reuses the
            // view for a different item, `onAppear` does not fire again, and the
            // editor keeps showing — and then saves — the previous item's values.
            ItemEditorView(itemID: id).id("\(id)-\(appState.session.sessionGeneration)")
        } else {
            VaultPlaceholder(
                symbol: "sidebar.left",
                title: "Nothing selected",
                message: "Pick an item from the list, or choose File > New Item.")
        }
    }
}
