import SwiftUI
import Core
import VaultSecurity

struct VaultWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedItemID: UUID?
    @State private var search: String = ""
    @State private var error: String?
    @State private var pendingDeleteID: UUID?

    private var payload: VaultPayload? { appState.session.currentPayload }

    var body: some View {
        Group {
            if !(appState.session.existsVault()) {
                VStack(spacing: 16) {
                    Text("No vault yet").font(.title2)
                    Button("Create Vault") { Task { try? await appState.session.createNewVault() } }
                    if let e = appState.session.lastError { Text(e).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !appState.session.isUnlocked {
                VStack(spacing: 16) {
                    Text("Vault locked").font(.title2)
                    Button("Unlock") { Task { try? await appState.session.unlock() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    sidebar
                        .frame(minWidth: 220, idealWidth: 260)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Vault")
    }

    private var filteredItems: [VaultItem] {
        guard let p = payload else { return [] }
        let q = search.lowercased()
        if q.isEmpty { return p.items.sorted { $0.sortOrder < $1.sortOrder } }
        return p.items.filter { $0.title.lowercased().contains(q) || $0.fields.contains(where: { $0.label.lowercased().contains(q) }) }
    }

    private var sidebar: some View {
        VStack {
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).padding(8)
            List(selection: $selectedItemID) {
                ForEach(filteredItems) { item in
                    Label(item.title, systemImage: "doc.text").tag(item.id)
                }
            }
            HStack {
                Button {
                    Task {
                        var newItem = VaultItem(title: "New Item")
                        await (try? appState.session.mutate { p in
                            newItem.sortOrder = p.items.count
                            p.items.append(newItem)
                        })
                        selectedItemID = newItem.id
                    }
                } label: { Image(systemName: "plus") }
                Menu {
                    ForEach(Templates.all(), id: \.0) { name, icon, build in
                        Button {
                            Task {
                                var newItem = build()
                                await (try? appState.session.mutate { p in
                                    newItem.sortOrder = p.items.count
                                    p.items.append(newItem)
                                })
                                selectedItemID = newItem.id
                            }
                        } label: { Label(name, systemImage: icon) }
                    }
                } label: { Image(systemName: "doc.badge.plus") }
                Button {
                    pendingDeleteID = selectedItemID
                } label: { Image(systemName: "trash") }.disabled(selectedItemID == nil)
                .confirmationDialog("Delete item?", isPresented: Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } })) {
                    Button("Delete", role: .destructive) {
                        if let id = pendingDeleteID {
                            Task {
                                try? await appState.session.mutate { p in p.items.removeAll { $0.id == id } }
                                selectedItemID = nil
                                pendingDeleteID = nil
                            }
                        }
                    }
                }
            }.padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedItemID, let _ = payload?.items.first(where: { $0.id == id }) {
            ItemEditorView(itemID: id)
        } else {
            Text("Select an item").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
}

struct ItemEditorView: View {
    @EnvironmentObject var appState: AppState
    let itemID: UUID
    @State private var item: VaultItem = VaultItem(title: "")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $item.title)
                    .font(.title3.bold())
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Add Field") {
                        var f = VaultField(key: "field\(UUID().uuidString.prefix(4))", label: "New Field", type: .text)
                        f.sortOrder = item.fields.count
                        item.fields.append(f)
                    }
                    Spacer()
                }
                ForEach(item.fields) { field in
                    FieldEditorRow(item: $item, fieldID: field.id)
                }
            }
            .padding()
        }
        .onChange(of: item) { _, v in save(v) }
        .onAppear {
            if let fresh = appState.session.currentPayload?.items.first(where: { $0.id == itemID }) { item = fresh }
        }
    }

    private func save(_ v: VaultItem) {
        Task {
            do {
                try await appState.session.mutate { p in
                    if let i = p.items.firstIndex(where: { $0.id == itemID }) { p.items[i] = v }
                }
            } catch {
                await MainActor.run { appState.errorMessage = "Save failed: \\(error.localizedDescription)" }
            }
        }
    }
}

struct FieldEditorRow: View {
    @Binding var item: VaultItem
    let fieldID: UUID
    @State private var reveal: Bool = false

    private var fieldIndex: Int? { item.fields.firstIndex(where: { $0.id == fieldID }) }

    private var field: Binding<VaultField>? {
        guard let idx = fieldIndex else { return nil }
        return Binding(get: { item.fields[idx] }, set: { item.fields[idx] = $0 })
    }

    var body: some View {
        if let field {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Key", text: field.key).frame(width: 100)
                        TextField("Label", text: field.label)
                        Picker("Type", selection: field.type) {
                            ForEach(FieldType.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
                        }.frame(width: 110)
                        Picker("Sensitivity", selection: field.sensitivity) {
                            ForEach(SensitivityLevel.allCases, id: \.self) { s in Text(s.rawValue).tag(s) }
                        }.frame(width: 100)
                        Button(role: .destructive) {
                            item.fields.removeAll { $0.id == fieldID }
                        } label: { Image(systemName: "trash") }
                    }
                    .onChange(of: field.wrappedValue.type) { _, newType in
                        if newType == .secret {
                            if field.wrappedValue.sensitivity < .sensitive {
                                field.wrappedValue.sensitivity = .sensitive
                            }
                        }
                    }
                    valueEditor(for: field.wrappedValue.type, field: field)
                    TextField("Aliases (comma)", text: Binding(
                        get: { field.wrappedValue.aliases.joined(separator: ", ") },
                        set: { field.wrappedValue.aliases = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                    )).font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func valueEditor(for type: FieldType, field: Binding<VaultField>) -> some View {
        switch type {
        case .text, .email, .url, .phone, .custom:
            TextField("Value", text: Binding(get: {
                switch field.wrappedValue.value {
                case .text(let v), .email(let v), .url(let v), .phone(let v), .custom(let v): return v
                default: return field.wrappedValue.value.storageDescription
                }
            }, set: { val in
                switch type {
                case .email: field.wrappedValue.value = .email(val)
                case .url: field.wrappedValue.value = .url(val)
                case .phone: field.wrappedValue.value = .phone(val)
                case .custom: field.wrappedValue.value = .custom(val)
                default: field.wrappedValue.value = .text(val)
                }
            })).textFieldStyle(.roundedBorder)
        case .multiline:
            TextEditor(text: Binding(get: { if case .multiline(let v)=field.wrappedValue.value {return v}; return "" }, set: { field.wrappedValue.value = .multiline($0) }))
                .frame(height: 60).overlay(RoundedRectangle(cornerRadius:4).stroke(.separator))
        case .secret:
            HStack {
                if reveal { TextField("Value", text: Binding(get: { if case .secret(let v)=field.wrappedValue.value {return v}; return "" }, set: { field.wrappedValue.value = .secret($0) })).textFieldStyle(.roundedBorder) }
                else { SecureField("Value", text: Binding(get: { if case .secret(let v)=field.wrappedValue.value {return v}; return "" }, set: { field.wrappedValue.value = .secret($0) })).textFieldStyle(.roundedBorder) }
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
            }
        case .number:
            TextField("Value", text: Binding(get: { if case .number(let v)=field.wrappedValue.value { return v.map{String($0)} ?? "" }; return "" }, set: { field.wrappedValue.value = .number(Double($0)) }))
                .textFieldStyle(.roundedBorder)
        case .boolean:
            Toggle("Value", isOn: Binding(get: { if case .boolean(let v)=field.wrappedValue.value {return v}; return false }, set: { field.wrappedValue.value = .boolean($0) }))
        case .date:
            DatePicker("Value", selection: Binding(get: { if case .date(let v)=field.wrappedValue.value {return v}; return Date() }, set: { field.wrappedValue.value = .date($0) }), displayedComponents: .date)
        }
    }
}
