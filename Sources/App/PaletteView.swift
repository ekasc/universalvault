import SwiftUI
import Core

struct PaletteView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search fields…", text: $appState.paletteQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { appState.insertSelected() }
                    .onChange(of: appState.paletteQuery) { _, _ in appState.refreshResults() }
            }
            .padding(10)
            Divider()
            List(selection: Binding(get: { appState.paletteResults.indices.contains(appState.paletteSelection) ? appState.paletteResults[appState.paletteSelection].id : nil }, set: { _ in })) {
                ForEach(Array(appState.paletteResults.enumerated()), id: \.element.id) { idx, res in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(res.field.label).font(.body)
                            Text("\(res.item.title) · \(res.categoryName ?? "Uncategorized")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(maskedPreview(res.field)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if res.field.sensitivity != .normal {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.paletteSelection = idx
                        appState.insertSelected()
                    }
                    .background(idx == appState.paletteSelection ? Color.accentColor.opacity(0.2) : .clear)
                }
            }
            .listStyle(.plain)
            Divider()
            HStack {
                Text("↑↓ navigate").font(.caption2)
                Text("↩ insert").font(.caption2)
                Text("Esc close").font(.caption2)
                Spacer()
            }
            .padding(6)
            .foregroundStyle(.secondary)
        }
        .frame(width: 520, height: 420)
        .onAppear { focused = true }
        .onKeyPress(.escape) { appState.dismissPalette(); return .handled }
        .onKeyPress(.downArrow) { appState.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { appState.moveSelection(-1); return .handled }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            // no-op
        }
    }

    private func maskedPreview(_ f: VaultField) -> String {
        switch f.sensitivity {
        case .normal:
            let s = f.value.storageDescription
            return s.count > 24 ? String(s.prefix(24)) + "…" : s
        case .sensitive, .critical:
            return "••••"
        }
    }
}
