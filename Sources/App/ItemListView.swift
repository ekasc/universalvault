import SwiftUI
import Core

/// The item list for the current scope. It is the window's navigation column:
/// the scope header replaces a separate sidebar, and all item actions live in
/// the context menu, the create menu, and the menu bar.
struct ItemListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: VaultSelection?
    @Binding var selectedItemID: UUID?

    @State private var search = ""
    @State private var pendingDeletion: PendingItemDeletion?
    @FocusState private var searchFocused: Bool

    private var payload: VaultPayload? { appState.session.currentPayload }
    private var allItems: [VaultItem] { payload?.items ?? [] }
    private var activeSelection: VaultSelection { selection ?? .allItems }
    private var visible: [VaultItem] {
        VaultBrowser.items(allItems, selection: activeSelection, search: search)
    }
    private var selectedItem: VaultItem? { visible.first { $0.id == selectedItemID } }

    private var commandActions: VaultItemActions {
        VaultItemActions(
            newItem: addItem,
            find: { searchFocused = true },
            duplicate: selectedItem.map { item in { duplicateItem(item.id) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            VaultScopeHeader(
                selection: $selection,
                itemCount: visible.count,
                onNewItem: addItem,
                onNewFromTemplate: addItem(from:))
            Hairline()
            content
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search items")
        .searchFocused($searchFocused)
        .focusedSceneValue(\.vaultItems, pendingDeletion == nil ? commandActions : nil)
        .confirmationDialog(
            "Delete item?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { request in
            Button("Delete", role: .destructive) {
                appState.edit({ payload in
                    guard request.generation == appState.session.sessionGeneration else { throw VaultEditError.staleConfirmation }
                    try payload.deleteItem(request.item)
                }, onSuccess: {
                    if selectedItemID == request.id { selectedItemID = nil }
                })
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { request in
            Text("\(request.item.title) and all of its fields will be removed. Use Vault > Undo Vault Change to restore them before locking.")
        }
        .onChange(of: appState.session.sessionGeneration) { _, _ in pendingDeletion = nil }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if allItems.isEmpty {
            VaultPlaceholder(
                symbol: "tray",
                title: "No items yet",
                message: "Add your first item to start filling fields.",
                actionLabel: "Add Item",
                action: addItem)
        } else if visible.isEmpty {
            VaultPlaceholder(
                symbol: "magnifyingglass",
                title: "No matches",
                message: search.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Nothing is filed here yet."
                    : "No item matches “\(search)”.")
        } else {
            List(selection: $selectedItemID) {
                ForEach(visible) { item in
                    row(item).tag(item.id)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Items")
            .focusedValue(\.vaultDeleteItem, pendingDeletion == nil
                ? selectedItem.map { item in { requestDeletion(item.id) } } : nil)
            .onDeleteCommand {
                if let selectedItem { requestDeletion(selectedItem.id) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first {
                    Button("Duplicate Item") { duplicateItem(id) }
                    Button("Move Up") { moveItem(id, by: -1) }.disabled(!search.isEmpty || visible.first?.id == id)
                    Button("Move Down") { moveItem(id, by: 1) }.disabled(!search.isEmpty || visible.last?.id == id)
                    Button("Delete Item…", role: .destructive) { requestDeletion(id) }
                }
            }
        }
    }

    private func row(_ item: VaultItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: ItemIcon.symbol(for: item))
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Theme.primary)
                    // Protection state at a glance; the subtitle already says
                    // "Locked" or "Protected" for anyone who cannot see it.
                    if item.isSensitive {
                        Image(systemName: item.isLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(Theme.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                Text(subtitle(item))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(subtitle(item))
        .accessibilityAddTraits(selectedItemID == item.id ? [.isSelected] : [])
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard search.isEmpty, values.count == 1, let id = UUID(uuidString: values[0]),
                  let source = visible.firstIndex(where: { $0.id == id }),
                  let target = visible.firstIndex(where: { $0.id == item.id }), source != target else { return false }
            moveItem(id, by: target - source)
            return true
        }
    }

    private func subtitle(_ item: VaultItem) -> String {
        var parts: [String] = []
        if let id = item.categoryID, let name = payload?.categories.first(where: { $0.id == id })?.name {
            parts.append(name)
        }
        if let id = item.profileID, let name = payload?.profiles.first(where: { $0.id == id })?.name {
            parts.append(name)
        }
        // A locked item's fields are absent by design, so the count would read as
        // an empty record. Say what the state actually is.
        if item.isLocked {
            parts.append("Locked")
        } else {
            let fields = item.fields.count
            parts.append(fields == 1 ? "1 field" : "\(fields) fields")
            if item.isSensitive { parts.append("Protected") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func duplicateItem(_ id: UUID) {
        appState.edit({ $0.duplicateItem(id) }, onSuccess: { copy in
            if let copy { selectedItemID = copy }
        })
    }

    private func moveItem(_ id: UUID, by offset: Int) {
        appState.edit(actionName: "Reorder Items") { try $0.moveItem(id, by: offset, in: activeSelection) }
    }

    private func requestDeletion(_ id: UUID) {
        guard let item = allItems.first(where: { $0.id == id }) else { return }
        pendingDeletion = PendingItemDeletion(item: item, generation: appState.session.sessionGeneration)
    }

    /// New items land in whatever scope the header is showing, which is what
    /// makes creating inside a category feel like it worked.
    private var scopeCategoryID: UUID? {
        if case .category(let id) = activeSelection { return id }
        return nil
    }

    private var scopeProfileID: UUID? {
        if case .profile(let id) = activeSelection { return id }
        return nil
    }

    private func addItem() {
        appState.edit({ payload in
            payload.addItem(categoryID: scopeCategoryID, profileID: scopeProfileID)
        }, onSuccess: { selectedItemID = $0 })
    }

    private func addItem(from template: Core.Template) {
        appState.edit({ payload in
            var item = template.build()
            item.categoryID = scopeCategoryID
            item.profileID = scopeProfileID
            item.sortOrder = VaultBrowser.nextItemSortOrder(payload.items)
            payload.items.append(item)
            return item.id
        }, onSuccess: { selectedItemID = $0 })
    }
}

private struct PendingItemDeletion: Identifiable {
    let item: VaultItem
    let generation: UUID
    var id: UUID { item.id }
}
