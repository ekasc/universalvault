import Core
import SwiftUI

/// The list pane's header: the current scope as a menu, a count, and one create
/// menu. Categories, profiles, and their management live here so the window
/// needs no separate navigation column.
struct VaultScopeHeader: View {
  @EnvironmentObject var appState: AppState
  @Binding var selection: VaultSelection?
  var itemCount: Int
  var onNewItem: () -> Void
  var onNewFromTemplate: (Core.Template) -> Void

  @State private var nameEntry: NameEntry?
  @State private var pendingDeletion: PendingSidebarDeletion?

  private var payload: VaultPayload? { appState.session.currentPayload }
  private var categories: [VaultCategory] { payload?.categories ?? [] }
  private var profiles: [Profile] { payload?.profiles ?? [] }

  private var scopeTitle: String {
    switch selection ?? .allItems {
    case .allItems: return "All Items"
    case .category(let id): return categories.first { $0.id == id }?.name ?? "All Items"
    case .profile(let id): return profiles.first { $0.id == id }?.name ?? "All Items"
    }
  }

  private var currentCategoryID: UUID? {
    if case .category(let id) = selection { return id }
    return nil
  }

  var body: some View {
    HStack(spacing: 6) {
      Menu {
        Picker("Scope", selection: $selection) {
          Text("All Items").tag(Optional(VaultSelection.allItems))
          if !categories.isEmpty {
            Divider()
            ForEach(VaultBrowser.categoryRows(categories)) { row in
              Text(String(repeating: "  ", count: row.depth) + row.category.name)
                .tag(Optional(VaultSelection.category(row.category.id)))
            }
          }
          if !profiles.isEmpty {
            Divider()
            ForEach(profiles.sorted { $0.sortOrder < $1.sortOrder }) { profile in
              Text(profile.name).tag(Optional(VaultSelection.profile(profile.id)))
            }
          }
        }
        Divider()
        Button("Rename…") { beginRenameSelected() }
          .disabled(deleteTarget == nil)
        Button("Delete…", role: .destructive) { requestDeletion() }
          .disabled(deleteTarget == nil)
      } label: {
        Text(scopeTitle)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Theme.primary)
          .lineLimit(1)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Scope")
      .accessibilityValue(scopeTitle)

      Text("\(itemCount)")
        .font(Typography.monoMicro)
        .foregroundStyle(Theme.tertiary)
        .accessibilityHidden(true)

      Spacer(minLength: 6)

      Menu {
        Button("New Item") { onNewItem() }
        Menu("New from Template") {
          ForEach(Templates.all(), id: \.name) { template in
            Button {
              onNewFromTemplate(template)
            } label: {
              Label(template.name, systemImage: template.icon)
            }
          }
        }
        Divider()
        Button(currentCategoryID == nil ? "New Category…" : "New Subcategory…") {
          beginNewCategory(parentID: currentCategoryID)
        }
        Button("New Profile…") { beginNewProfile() }
      } label: {
        Label("New", systemImage: "plus")
          .labelStyle(.iconOnly)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.secondary)
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("New item, category, or profile")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .focusedSceneValue(
      \.vaultSidebar,
      nameEntry == nil && pendingDeletion == nil
        ? VaultSidebarActions(
          newCategory: { beginNewCategory(parentID: nil) },
          newProfile: beginNewProfile,
          rename: deleteTarget.map { _ in beginRenameSelected })
        : nil)
    .sheet(item: $nameEntry) { entry in
      NameEntrySheet(entry: entry) { name in try await commit(entry, name: name) }
    }
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(
        get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
      titleVisibility: .visible,
      presenting: pendingDeletion
    ) { request in
      Button("Delete", role: .destructive) { performDelete(request) }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: { request in
      Text(request.target.consequence)
    }
    .onChange(of: appState.session.sessionGeneration) { _, _ in pendingDeletion = nil }
  }

  // MARK: - Selection targets

  private var deleteTarget: SidebarDeletion? {
    switch selection {
    case .category(let id):
      guard let category = categories.first(where: { $0.id == id }) else { return nil }
      return .category(category)
    case .profile(let id):
      guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
      return .profile(profile)
    case .allItems, nil:
      return nil
    }
  }

  private var deleteTitle: String {
    switch pendingDeletion?.target {
    case .category: return "Delete category?"
    case .profile: return "Delete profile?"
    case nil: return ""
    }
  }

  private func beginRenameSelected() {
    switch deleteTarget {
    case .category(let category): beginRename(category)
    case .profile(let profile): beginRename(profile)
    case nil: break
    }
  }

  private func beginRename(_ category: VaultCategory) {
    nameEntry = NameEntry(
      kind: .renameCategory(category.id), title: "Rename Category",
      prompt: "Category name", initialName: category.name,
      generation: appState.session.sessionGeneration)
  }

  private func beginRename(_ profile: Profile) {
    nameEntry = NameEntry(
      kind: .renameProfile(profile.id), title: "Rename Profile",
      prompt: "Profile name", initialName: profile.name,
      generation: appState.session.sessionGeneration)
  }

  private func beginNewProfile() {
    nameEntry = NameEntry(
      kind: .newProfile, title: "New Profile", prompt: "Profile name",
      initialName: "", generation: appState.session.sessionGeneration)
  }

  private func beginNewCategory(parentID: UUID?) {
    nameEntry = NameEntry(
      kind: .newCategory(parent: parentID), title: "New Category",
      prompt: "Category name", initialName: "",
      generation: appState.session.sessionGeneration)
  }

  private func commit(_ entry: NameEntry, name: String) async throws {
    guard entry.generation == appState.session.sessionGeneration else {
      throw VaultEditError.staleConfirmation
    }
    switch entry.kind {
    case .newCategory(let parent):
      let id = try await appState.session.mutate { try $0.addCategory(name: name, parentID: parent) }
      selection = .category(id)
    case .renameCategory(let id):
      try await appState.session.mutate { try $0.renameCategory(id, to: name) }
    case .newProfile:
      let id = try await appState.session.mutate { try $0.addProfile(name: name) }
      selection = .profile(id)
    case .renameProfile(let id):
      try await appState.session.mutate { try $0.renameProfile(id, to: name) }
    }
  }

  private func requestDeletion() {
    guard let target = deleteTarget else { return }
    pendingDeletion = PendingSidebarDeletion(
      target: target, generation: appState.session.sessionGeneration)
  }

  private func performDelete(_ request: PendingSidebarDeletion) {
    appState.edit({ payload in
      guard request.generation == appState.session.sessionGeneration else {
        throw VaultEditError.staleConfirmation
      }
      switch request.target {
      case .category(let category): try payload.deleteCategory(category)
      case .profile(let profile): try payload.deleteProfile(profile)
      }
    }, onSuccess: {
      switch (request.target, selection) {
      case (.category(let category), .category(let id)) where category.id == id:
        selection = .allItems
      case (.profile(let profile), .profile(let id)) where profile.id == id:
        selection = .allItems
      default:
        break
      }
    })
    pendingDeletion = nil
  }
}

private struct PendingSidebarDeletion: Identifiable {
  let target: SidebarDeletion
  let generation: UUID
  var id: String { target.id }
}

/// What the scope header can create, rename, or delete.
enum SidebarDeletion: Identifiable {
  case category(Core.VaultCategory)
  case profile(Profile)

  var id: String {
    switch self {
    case .category(let category): return "category-\(category.id)"
    case .profile(let profile): return "profile-\(profile.id)"
    }
  }

  var consequence: String {
    switch self {
    case .category(let category):
      return
        "Subcategories move up one level. Items in \(category.name) are kept and become uncategorized."
    case .profile(let profile):
      return "Items assigned to \(profile.name) are kept and become unassigned."
    }
  }
}

struct NameEntry: Identifiable {
  enum Kind {
    case newCategory(parent: UUID?)
    case renameCategory(UUID)
    case newProfile
    case renameProfile(UUID)
  }

  let id = UUID()
  let kind: Kind
  let title: String
  let prompt: String
  let initialName: String
  let generation: UUID
}

private struct NameEntrySheet: View {
  let entry: NameEntry
  let onCommit: (String) async throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String = ""
  @State private var saving = false
  @State private var failure: String?
  @FocusState private var focused: Bool

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(entry.title).font(.headline)

      TextField(entry.prompt, text: $name)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .accessibilityLabel(entry.prompt)
        .disabled(saving)

      if let failure {
        Text("Save failed: \(failure)")
          .font(.caption)
          .foregroundStyle(.primary)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(saving)
        Button(saving ? "Saving…" : "Save") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(trimmed.isEmpty || saving)
      }
    }
    .padding(20)
    .frame(width: 340)
    .interactiveDismissDisabled(saving)
    .onAppear {
      name = entry.initialName
      focused = true
    }
  }

  private func commit() {
    guard !trimmed.isEmpty, !saving else { return }
    let value = trimmed
    saving = true
    failure = nil
    Task { @MainActor in
      defer { saving = false }
      do {
        try await onCommit(value)
        dismiss()
      } catch {
        failure = error.localizedDescription
      }
    }
  }
}
