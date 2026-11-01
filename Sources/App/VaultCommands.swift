import SwiftUI

struct VaultItemActions {
    let newItem: () -> Void
    let find: () -> Void
    let duplicate: (() -> Void)?
}

struct VaultSidebarActions {
    let newCategory: () -> Void
    let newProfile: () -> Void
    let rename: (() -> Void)?
}

private struct VaultItemActionsKey: FocusedValueKey {
    typealias Value = VaultItemActions
}

private struct VaultSidebarActionsKey: FocusedValueKey {
    typealias Value = VaultSidebarActions
}

private struct VaultAddFieldKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct VaultDeleteItemKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var vaultItems: VaultItemActions? {
        get { self[VaultItemActionsKey.self] }
        set { self[VaultItemActionsKey.self] = newValue }
    }

    var vaultSidebar: VaultSidebarActions? {
        get { self[VaultSidebarActionsKey.self] }
        set { self[VaultSidebarActionsKey.self] = newValue }
    }

    var vaultAddField: (() -> Void)? {
        get { self[VaultAddFieldKey.self] }
        set { self[VaultAddFieldKey.self] = newValue }
    }

    var vaultDeleteItem: (() -> Void)? {
        get { self[VaultDeleteItemKey.self] }
        set { self[VaultDeleteItemKey.self] = newValue }
    }
}

struct VaultCommands: Commands {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.vaultItems) private var items
    @FocusedValue(\.vaultSidebar) private var sidebar
    @FocusedValue(\.vaultAddField) private var addField
    @FocusedValue(\.vaultDeleteItem) private var deleteItem

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Vault") { openWindow(id: "vault") }
                .keyboardShortcut("o")
            Divider()
            Button("New Item") { items?.newItem() }
                .keyboardShortcut("n")
                .disabled(items == nil)
            Button("New Category…") { sidebar?.newCategory() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(sidebar == nil)
            Button("New Profile…") { sidebar?.newProfile() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(sidebar == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Duplicate Item") { items?.duplicate?() }
                .keyboardShortcut("d")
                .disabled(items?.duplicate == nil)
            Button("Delete Item…") { deleteItem?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteItem == nil)
            Button("Rename Category or Profile…") { sidebar?.rename?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(sidebar?.rename == nil)
            Button("Add Field") { addField?() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(addField == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Items") { items?.find() }
                .keyboardShortcut("f")
                .disabled(items == nil)
        }
        CommandMenu("Vault") {
            Button("Undo \(appState.session.undoActionName)") {
                Task { await appState.restoreHistory(undo: true) }
            }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!appState.session.canUndo)
            Button("Redo \(appState.session.redoActionName)") {
                Task { await appState.restoreHistory(undo: false) }
            }
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                .disabled(!appState.session.canRedo)
            Divider()
            Button("Quick Fill…") { appState.invokePalette() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!appState.session.isUnlocked)
            Button(appState.session.isUnlocked ? "Lock Vault" : "Unlock Vault") { appState.toggleLock() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!appState.session.existsVault())
        }
        SidebarCommands()
        ToolbarCommands()
        CommandGroup(replacing: .help) {
            Button("UniversalVault Help") { openWindow(id: "onboarding") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
