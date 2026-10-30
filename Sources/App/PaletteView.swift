import SwiftUI
import Core
import AppKit
import Insertion

struct PaletteView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let notice = appState.paletteNotice {
                noticeBar(notice)
            }
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            searchFocused = true
            // The panel may not be key yet on first presentation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
        .onChange(of: appState.focusToken) { _, _ in
            searchFocused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search the vault…", text: $appState.paletteQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
                .onSubmit { appState.insertSelected() }
                .onChange(of: appState.paletteQuery) { _, _ in appState.queryChanged() }
            if appState.isAuthenticating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(notice).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !AccessibilityPermission.isTrusted() {
                Button("Grant Access…") {
                    _ = AccessibilityPermission.requestPrompt()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private var content: some View {
        if appState.paletteResults.isEmpty {
            VStack(spacing: 6) {
                Text(appState.paletteQuery.isEmpty ? "Nothing to fill" : "No matching fields")
                    .font(.headline)
                Text(appState.paletteQuery.isEmpty
                     ? "Add items and fields in the vault window."
                     : "Try a label, item name, or alias.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(appState.paletteResults.enumerated()), id: \.element.id) { idx, res in
                        row(res, index: idx)
                            .id(res.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: appState.paletteSelection) { _, newValue in
                    guard appState.paletteResults.indices.contains(newValue) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(appState.paletteResults[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(_ res: SearchResult, index: Int) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(res.field.label)
                    .font(.body)
                    .lineLimit(1)
                Text("\(res.item.title) · \(res.categoryName ?? "Uncategorized")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(maskedPreview(res.field))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if res.field.sensitivity != .normal {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.paletteSelection = index
            appState.insertSelected()
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(index == appState.paletteSelection ? Color.accentColor.opacity(0.22) : .clear)
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("click to fill")
            Text("↑↓ then ↩")
            Text("esc")
            Spacer()
            Text("⌃⌥V")
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
    }

    private func maskedPreview(_ f: VaultField) -> String {
        switch f.sensitivity {
        case .normal:
            let s = f.value.insertionText
            return s.count > 32 ? String(s.prefix(32)) + "…" : s
        case .sensitive, .critical:
            return "••••"
        }
    }
}
