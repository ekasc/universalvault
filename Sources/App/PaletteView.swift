import SwiftUI
import Core
import Insertion

/// The Quick Fill surface: one plane, an open search row, inset selection pills,
/// and a footer that names the application the value will be inserted into.
///
/// The window around it is sized from `PaletteMetrics`, so the measurements here
/// are shared with `PalettePanelController` rather than guessed.
struct PaletteView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var focused: Bool

    private var payload: VaultPayload? { appState.session.currentPayload }
    private var previewsEnabled: Bool { payload?.settings.showValuePreviews == true }
    private var totalFieldCount: Int { payload?.items.reduce(0) { $0 + $1.fields.count } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Hairline()
            content
            Hairline()
            footer
        }
        .frame(minWidth: PaletteMetrics.minWidth, maxWidth: .infinity,
               minHeight: 0, maxHeight: .infinity)
        .background(Theme.canvas)
        // The panel is transparent so the window server does not paint a square
        // titlebar above a rounded surface. The surface itself is this shape.
        .clipShape(RoundedRectangle(cornerRadius: PaletteMetrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PaletteMetrics.radius, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .onAppear { focused = true }
        // The panel is a single long-lived NSHostingView that is ordered out and
        // back in. `onAppear` is not guaranteed to fire on re-presentation, so
        // focus is re-asserted on every presentation rather than relying on it.
        .onChange(of: appState.showPalette) { _, visible in
            if visible { focused = true }
        }
        // The vault can be edited in its own window while the palette is open.
        // Results are recomputed on a payload change, not only on a query change.
        .onChange(of: payload?.updatedAt) { _, _ in appState.refreshResults() }
        // The panel is sized to its contents, so a filter that changes the number
        // of rows has to reach the window. Without this the last row is clipped
        // and the footer floats in empty space.
        .onChange(of: appState.paletteResults.count) { _, _ in
            PalettePanelController.shared?.resultsChanged()
        }
        // Protected items appear and disappear with the sensitive key, not with
        // the query. Deferred, because publishing results during a view update is
        // what the window resize below must also avoid.
        .onChange(of: appState.session.isSensitiveUnlocked) { _, _ in
            Task { @MainActor in appState.refreshResults() }
        }
        .onKeyPress(.escape) { appState.dismissPalette(); return .handled }
        // Mutual exclusion is no longer needed: arrows always move the palette
        // selection, and the rows are not focusable. The guard keeps the key
        // handler from acting while the search field is being edited.
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        // Return is handled by the focused search field's submit. Ignore it here
        // while the field has focus so one press does not insert twice.
        .onKeyPress(.return) {
            guard !focused else { return .ignored }
            appState.insertSelected()
            return .handled
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard focused else { return .ignored }
        appState.moveSelection(delta)
        return .handled
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: PaletteScale.size(13), weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            TextField("Search fields…", text: $appState.paletteQuery)
                .textFieldStyle(.plain)
                .font(.system(size: PaletteScale.size(16)))
                .foregroundStyle(Theme.primary)
                .focused($focused)
                .onSubmit { appState.insertSelected() }
                .onChange(of: appState.paletteQuery) { _, _ in appState.refreshResults() }
                .accessibilityLabel("Search fields")
                .accessibilityHint("Press Return to insert the highlighted value.")
            if !appState.paletteQuery.isEmpty {
                Button {
                    appState.paletteQuery = ""
                    appState.refreshResults()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: PaletteScale.size(13)))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, PaletteScale.length(PaletteMetrics.sidePadding))
        .frame(height: PaletteScale.length(PaletteMetrics.searchHeight))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appState.paletteResults.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: PaletteScale.length(PaletteMetrics.rowSpacing)) {
                        ForEach(Array(appState.paletteResults.enumerated()), id: \.element.id) { index, result in
                            row(result, index: index).id(result.id)
                        }
                    }
                    .padding(.vertical, PaletteScale.length(PaletteMetrics.listPadding))
                }
                .onChange(of: appState.paletteSelection) { _, _ in
                    guard appState.paletteResults.indices.contains(appState.paletteSelection) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(appState.paletteResults[appState.paletteSelection].id)
                    }
                }
            }
            .accessibilityLabel("Matching fields")
        }
    }

    private var sealedItemCount: Int {
        appState.session.isSensitiveUnlocked ? 0 : appState.session.lockedItemCount
    }

    private func unlockProtectedItems() {
        Task { @MainActor in
            let count = appState.session.lockedItemCount
            // The panel unlocks every sealed item until they close again, not
            // one at a time. Say so in the system prompt.
            let reason =
                count == 1
                ? "Unlock 1 protected item until the vault seals again"
                : "Unlock \(count) protected items until the vault seals again"
            try? await appState.session.unlockSensitiveItems(reason: reason)
            appState.refreshResults()
        }
    }

    private var lockedItemsProhibitingResults: Bool {
        appState.session.lockedItemCount > 0 && !appState.session.isSensitiveUnlocked
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: lockedItemsProhibitingResults ? "lock.fill"
                  : totalFieldCount == 0 ? "tray" : "magnifyingglass")
                .font(.system(size: PaletteScale.size(21), weight: .light))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            Text(emptyStateTitle)
                .font(.system(size: PaletteScale.size(18), weight: .medium, design: .serif))
                .foregroundStyle(Theme.primary)
            Text(emptyStateDetail)
                .font(.system(size: PaletteScale.size(12.5)))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if lockedItemsProhibitingResults {
                Button("Unlock with Touch ID") { unlockProtectedItems() }
                .buttonStyle(.link)
                .accessibilityIdentifier("palette.unlockProtected")
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var queryIsEmpty: Bool {
        appState.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only claim the lock is why the list is empty when the query is empty too.
    /// Otherwise a query that simply matches nothing would be blamed on the lock.
    private var emptyStateTitle: String {
        if lockedItemsProhibitingResults && queryIsEmpty { return "Protected items are locked" }
        if totalFieldCount == 0 && !lockedItemsProhibitingResults {
            return "This vault has no fields yet"
        }
        return "No matching fields"
    }

    private var emptyStateDetail: String {
        if lockedItemsProhibitingResults {
            let count = appState.session.lockedItemCount
            let sealed =
                count == 1 ? "1 protected item is sealed" : "\(count) protected items are sealed"
            return queryIsEmpty
                ? "\(sealed) until you unlock it."
                : "\(sealed). Unlocking includes its fields in this search."
        }
        return totalFieldCount == 0
            ? "Add items and fields in the vault window before using quick fill."
            : "Try a different word, or clear the search."
    }

    private func row(_ result: SearchResult, index: Int) -> some View {
        let selected = index == appState.paletteSelection
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.field.label)
                    .font(.system(size: PaletteScale.size(13), weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(context(for: result))
                    .font(.system(size: PaletteScale.size(11.5)))
                    .foregroundStyle(selected ? Theme.secondary : Theme.tertiary)
                    .lineLimit(1)
            }
            // The label keeps its width; a long value truncates instead of
            // pushing the field name out of the row.
            .layoutPriority(1)
            Spacer(minLength: 12)
            if previewsEnabled {
                Text(preview(result.field))
                    .font(.system(size: PaletteScale.size(12.5), design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PaletteScale.length(PaletteMetrics.rowHeight))
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.selection : Color.clear)
        )
        .padding(.horizontal, PaletteMetrics.rowInset)
        .contentShape(Rectangle())
        .onHover { hovering in
            // Hovering moves the selection, so the row under the pointer is the
            // row that Return would insert.
            if hovering, appState.paletteSelection != index { appState.paletteSelection = index }
        }
        .onTapGesture {
            appState.paletteSelection = index
            appState.insertSelected()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.field.label)
        .accessibilityValue(accessibilityValue(result))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Insert") {
            appState.paletteSelection = index
            appState.insertSelected()
        }
    }

    private func context(for result: SearchResult) -> String {
        var parts = [result.item.title]
        parts.append(result.categoryName ?? "Uncategorized")
        if let profile = result.profileName { parts.append(profile) }
        return parts.joined(separator: " · ")
    }

    /// Sensitivity is stated in words rather than left to a lock glyph, so it is
    /// not lost on anyone who cannot see the icon.
    private func accessibilityValue(_ result: SearchResult) -> String {
        var parts = [context(for: result)]
        switch result.field.sensitivity {
        case .normal: break
        case .sensitive: parts.append("sensitive")
        case .critical: parts.append("critical, requires authentication")
        }
        parts.append(previewsEnabled && result.field.sensitivity == .normal ? "value shown" : "value hidden")
        return parts.joined(separator: ", ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(statusText)
                .font(.system(size: PaletteScale.size(11.5)))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(statusText)
            if needsAccessibility {
                Button("Enable Access…") {
                    // Registers this exact binary with TCC and shows the system
                    // prompt. A grant made for an older signature does not apply
                    // to this build, so the entry has to be removed and re-added.
                    _ = AccessibilityPermission.requestPrompt()
                }
                .buttonStyle(.plain)
                .font(.system(size: PaletteScale.size(11.5), weight: .medium))
                .foregroundStyle(Theme.primary)
            }
            Spacer(minLength: 12)
            // Silent omission reads as "nothing there". When sealed items exist,
            // say so even while the result list is showing other matches.
            if sealedItemCount > 0 {
                Button { unlockProtectedItems() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: PaletteScale.size(9)))
                        Text(sealedItemCount == 1 ? "1 sealed" : "\(sealedItemCount) sealed")
                            .font(.system(size: PaletteScale.size(11)))
                    }
                    .foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Protected items are sealed. Unlock with Touch ID to include their fields.")
                .accessibilityLabel(
                    sealedItemCount == 1
                        ? "1 protected item is sealed. Unlock with Touch ID."
                        : "\(sealedItemCount) protected items are sealed. Unlock with Touch ID.")
                .accessibilityIdentifier("palette.sealedCount")
            }
            HStack(spacing: 12) {
                hint("↑↓", "navigate")
                hint("↵", "insert")
                hint("esc", "close")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Arrow keys navigate, Return inserts, Escape closes.")
        }
        .padding(.horizontal, PaletteMetrics.sidePadding)
        .frame(height: PaletteMetrics.footerHeight)
    }

    /// One status line. An insertion error wins because it is actionable, and it
    /// stays to a single line so the panel can be sized to an exact height.
    private var statusText: String {
        if let error = appState.errorMessage, !error.isEmpty { return error }
        if let name = appState.targetApplicationName { return "Insert into \(name)" }
        if needsAccessibility { return "Accessibility access is off." }
        return "Focus a text field, then reopen Quick Fill."
    }

    private var needsAccessibility: Bool {
        appState.targetApplicationName == nil && !AccessibilityPermission.isTrusted()
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Keycap(text: key)
            Text(action)
                .font(.system(size: PaletteScale.size(11)))
                .foregroundStyle(Theme.tertiary)
        }
    }

    /// Previews are opt-in (Settings → "Show value previews"), which is why the
    /// default is blank rather than a truncated value. Sensitive and critical
    /// values stay masked even when previews are on.
    private func preview(_ f: VaultField) -> String {
        guard previewsEnabled else { return "" }
        switch f.sensitivity {
        case .normal:
            let text = f.insertionText
            return text.count > 24 ? String(text.prefix(24)) + "…" : text
        case .sensitive, .critical:
            return "••••"
        }
    }
}
