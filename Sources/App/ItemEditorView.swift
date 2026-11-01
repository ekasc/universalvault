import Core
import SwiftUI

/// Editor for one item. Owned by a single item id; the parent applies `.id(id)`
/// so a different item always gets a fresh editor.
///
/// Structure is a record, not a form: serif title, one uppercase metadata line,
/// then hairline-separated field rows. Per-field options live behind a
/// disclosure so values stay the loudest thing on screen.
struct ItemEditorView: View {
  @EnvironmentObject var appState: AppState
  /// Leaving the app is the last chance to flush: termination clears the
  /// session, so a pending debounced write would be lost with it.
  @Environment(\.scenePhase) private var scenePhase
  let itemID: UUID

  @State private var item: VaultItem = VaultItem(title: "")
  @State private var lastSaved: VaultItem?
  @State private var conflict: String?
  @State private var editRevision = UUID()
  @State private var tagsText = ""
  @State private var showTagEditor = false
  @State private var saveChain: Task<Void, Never>?
  /// Pending debounced write; cancelled by the next keystroke.
  @State private var pendingSave: Task<Void, Never>?
  /// True when the item is protected and its fields are not in memory.
  @State private var isLocked = false
  /// When the last autosave landed; cleared shortly after so the badge fades.
  @State private var savedAt: Date?

  private var payload: VaultPayload? { appState.session.currentPayload }
  private var categories: [VaultCategory] { payload?.categories ?? [] }
  private var profiles: [Profile] { payload?.profiles ?? [] }

  private var categoryName: String {
    guard let id = item.categoryID,
      let category = categories.first(where: { $0.id == id })
    else { return "Uncategorized" }
    return category.name
  }

  private var profileName: String {
    guard let id = item.profileID, let profile = profiles.first(where: { $0.id == id })
    else { return "No profile" }
    return profile.name
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
        metadata.padding(.top, 8)
        if isLocked {
          lockedState.padding(.top, Metrics.sectionGap)
        } else {
          if let bannerMessage { validationBanner(bannerMessage).padding(.top, 18) }
          fields.padding(.top, Metrics.sectionGap)
        }
      }
      .padding(.horizontal, Metrics.contentPadding)
      .padding(.top, 24)
      .padding(.bottom, 32)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .background(Theme.canvas)
    .focusedSceneValue(\.vaultAddField, appendField)
    .onChange(of: item) { _, _ in scheduleSave() }
    .onDisappear { flushPendingSave() }
    .onChange(of: tagsText) { _, text in
      if let tags = CommaSeparatedValues.parse(text) { item.tags = tags }
    }
    // Locking protected items invalidates every draft; unlocking re-seeds the
    // fields that are now readable.
    .onChange(of: appState.session.isSensitiveUnlocked) { _, _ in seed() }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { flushPendingSave() }
    }
    .task(id: savedAt) {
      guard savedAt != nil else { return }
      try? await Task.sleep(for: .seconds(2))
      if !Task.isCancelled { savedAt = nil }
    }
    .onAppear { seed() }
  }

  /// Quiet confirmation that autosave ran. It says "Saved" rather than showing a
  /// spinner, because nothing is pending by the time it appears.
  @ViewBuilder
  private var savedBadge: some View {
    if savedAt != nil {
      HStack(spacing: 4) {
        Image(systemName: "checkmark")
          .font(.system(size: 9, weight: .semibold))
        Text("Saved")
          .font(Typography.meta)
      }
      .foregroundStyle(Theme.tertiary)
      .transition(.opacity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Changes saved")
      .accessibilityIdentifier("item.saved")
    }
  }

  /// Shown in place of the fields while the item's contents are sealed.
  private var lockedState: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "lock.fill")
          .font(.system(size: 12))
          .foregroundStyle(Theme.secondary)
          .accessibilityHidden(true)
        Text("Fields are protected")
          .font(Typography.emptyTitle)
          .foregroundStyle(Theme.primary)
      }
      Text("They are sealed with the Touch ID key and are not read until you open them.")
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Unlock with Touch ID") { unlockProtectedItem() }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("item.unlockProtected")
    }
    .frame(maxWidth: 420, alignment: .leading)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
  }

  private func unlockProtectedItem() {
    Task { @MainActor in
      do {
        // Unlocking is vault-wide until the items seal again, not per item.
        try await appState.session.unlockSensitiveItems(
            reason: "Unlock protected items to open “\(item.title)”")
        isLocked = false
        seed()
      } catch {
        conflict = error.localizedDescription
      }
    }
  }

  /// Marks the item as protected, or releases it. Protecting needs the sensitive
  /// key in hand, so the first protected item creates it behind Touch ID.
  private func toggleProtection() {
    let turningOn = !item.isSensitive
    Task { @MainActor in
      if turningOn {
        do {
          try await appState.session.unlockSensitiveItems(reason: "Protect “\(item.title)”")
        } catch {
          conflict = error.localizedDescription
          return
        }
      }
      item.isSensitive = turningOn
      // Protection wins over sharing: an item cannot stay visible to agents once
      // its fields become sealed.
      if turningOn { item.isShareableWithAgents = false }
    }
  }

  /// Shown when the form is out of step with what is stored: either a required
  /// value is cleared, or the item was changed from somewhere else.
  private var bannerMessage: String? {
    if let conflict { return conflict }
    let summary = item.validationSummary
    guard !summary.isEmpty else { return nil }
    return "\(summary) Required names keep their saved values. Other changes save automatically."
  }

  private func validationBanner(_ message: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(message)
        .font(.caption)
        .foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button("Reload saved item") { seed() }
        .accessibilityHint("Discards unfinished edits and loads the saved item.")
    }
    .padding(9)
    .background(Theme.well, in: RoundedRectangle(cornerRadius: Metrics.radius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(Theme.hairline))
    .accessibilityElement(children: .contain)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Menu {
        Button("No Icon") { item.icon = nil }
        Divider()
        ForEach(ItemIcon.presets, id: \.self) { symbol in
          Button {
            item.icon = symbol
          } label: {
            Label(symbol, systemImage: symbol)
          }
        }
      } label: {
        IconPlate(symbol: ItemIcon.symbol(for: item), size: 30)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Choose an icon")
      .accessibilityLabel("Item icon")
      .accessibilityValue(ItemIcon.symbol(for: item))

      TextField("Title", text: $item.title)
        .textFieldStyle(.plain)
        .font(Typography.recordTitle)
        .foregroundStyle(Theme.primary)
        .accessibilityLabel("Item title")
    }
  }

  // MARK: - Metadata

  private var metadata: some View {
    HStack(spacing: 14) {
      Menu {
        Picker("Category", selection: $item.categoryID) {
          Text("Uncategorized").tag(UUID?.none)
          ForEach(VaultBrowser.categoryRows(categories)) { row in
            Text(String(repeating: "  ", count: row.depth) + row.category.name)
              .tag(UUID?.some(row.category.id))
          }
        }
      } label: {
        metaMenuItem(categoryName, systemImage: "folder")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Category")
      .accessibilityValue(categoryName)

      Menu {
        Picker("Profile", selection: $item.profileID) {
          Text("None").tag(UUID?.none)
          ForEach(profiles.sorted { $0.sortOrder < $1.sortOrder }) { profile in
            Text(profile.name).tag(UUID?.some(profile.id))
          }
        }
      } label: {
        metaMenuItem(profileName, systemImage: "person")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Profile")
      .accessibilityValue(profileName)

      tags
      protectionButton
      agentSharingButton
      Spacer(minLength: 12)
      savedBadge
    }
    .padding(.leading, 42)
    .popover(isPresented: $showTagEditor, arrowEdge: .bottom) { tagEditor }
  }

  /// Opt-in inclusion in `--about-me`. A protected item can never be shared, so
  /// the control is disabled rather than silently ignored.
  private var agentSharingButton: some View {
    Button {
      item.isShareableWithAgents.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "person.2")
          .font(.system(size: 10))
        Text("AGENTS")
          .font(Typography.meta)
          .tracking(0.6)
      }
      .foregroundStyle(item.isShareableWithAgents ? Theme.primary : Theme.tertiary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .disabled(item.isSensitive)
    .help(item.isSensitive
      ? "Protected items are never shared with agents"
      : AgentProfile.sharesNothing(item) && item.isShareableWithAgents
        ? "Shared, but this item has no fields agents may read"
        : "Let agents read this item's non-sensitive fields")
    .accessibilityLabel("Share this item's non-sensitive fields with agents")
    .accessibilityValue(item.isShareableWithAgents ? "on" : "off")
    .accessibilityIdentifier("item.agentSharing")
  }

  /// One control for the whole item rather than a flag per field: the item is
  /// what the user thinks of as protected.
  private var protectionButton: some View {
    Button { toggleProtection() } label: {
      HStack(spacing: 5) {
        Image(systemName: item.isSensitive ? "lock.fill" : "lock.open")
          .font(.system(size: 10))
        Text(item.isSensitive ? "TOUCH ID" : "PROTECT")
          .font(Typography.meta)
          .tracking(0.6)
      }
      .foregroundStyle(item.isSensitive ? Theme.primary : Theme.tertiary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .disabled(isLocked)
    .help(isLocked
      ? "Unlock this item before removing its protection"
      : item.isSensitive
        ? "Fields are sealed with the Touch ID key"
        : "Require Touch ID to read this item's fields")
    .accessibilityLabel("Require Touch ID for this item")
    .accessibilityValue(item.isSensitive ? "on" : "off")
    .accessibilityIdentifier("item.protection")
  }

  private func metaMenuItem(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
        .font(.system(size: 10))
      Text(title.uppercased())
        .font(Typography.meta)
        .tracking(0.6)
    }
    .foregroundStyle(Theme.secondary)
  }

  private var tags: some View {
    HStack(spacing: 10) {
      ForEach(item.tags.prefix(3), id: \.self) { tag in
        Text("#\(tag.uppercased())")
          .font(Typography.monoMicro)
          .tracking(0.5)
          .foregroundStyle(Theme.tertiary)
      }
      if item.tags.count > 3 {
        Text("+\(item.tags.count - 3)")
          .font(Typography.monoMicro)
          .foregroundStyle(Theme.tertiary)
      }
      Button {
        showTagEditor = true
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Theme.tertiary)
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(item.tags.isEmpty ? "Add tags" : "Edit tags")
      .accessibilityLabel(item.tags.isEmpty ? "Add tags" : "Edit tags")
      .accessibilityValue(CommaSeparatedValues.format(item.tags))
    }
  }

  private var tagEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      MicroLabel("Tags")
      TextField("Comma separated", text: $tagsText)
        .wellField()
        .frame(width: 260)
        .accessibilityLabel("Tags")
        .accessibilityHint("Comma separated. Quote a tag that contains a comma.")
      if CommaSeparatedValues.parse(tagsText) == nil {
        Text("Finish the quoted tag to save it.")
          .font(.caption)
          .foregroundStyle(Theme.secondary)
      }
    }
    .padding(14)
  }

  // MARK: - Fields

  private var fields: some View {
    VStack(alignment: .leading, spacing: 0) {
      Hairline()
      HStack(spacing: 10) {
        MicroLabel("Fields")
        Text("\(item.fields.count)")
          .font(Typography.monoMicro)
          .foregroundStyle(Theme.tertiary)
        Spacer(minLength: 8)
        Button(action: appendField) {
          HStack(spacing: 4) {
            Image(systemName: "plus")
              .font(.system(size: 9, weight: .semibold))
            Text("Add Field")
              .font(.system(size: 12))
          }
          .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds an empty text field to this item.")
      }
      .padding(.top, 12)
      .padding(.bottom, 6)

      if item.fields.isEmpty {
        Text("No fields yet. Insertion works on the fields you add here.")
          .font(Typography.body)
          .foregroundStyle(Theme.secondary)
          .padding(.vertical, 14)
          .accessibilityLabel("No fields yet")
      } else {
        ForEach(Array(item.fields.enumerated()), id: \.element.id) { index, field in
          FieldEditorRow(item: $item, fieldID: field.id, showsTopDivider: index > 0)
        }
      }
    }
  }

  private func appendField() {
    var field = VaultField(
      key: "field\(UUID().uuidString.prefix(4))", label: "New Field", type: .text)
    field.sortOrder = item.fields.count
    item.fields.append(field)
  }

  // MARK: - Persistence

  private func seed() {
    guard let fresh = payload?.items.first(where: { $0.id == itemID }) else { return }
    editRevision = UUID()
    item = fresh
    isLocked = fresh.isLocked
    tagsText = CommaSeparatedValues.format(fresh.tags)
    lastSaved = fresh
    conflict = nil
  }

  /// Typing coalesces into one write after the burst. Each save re-encrypts the
  /// whole payload and rewrites the vault file, so saving per keystroke made a
  /// large vault untypeable; the trailing edge is what actually changed.
  private func scheduleSave() {
    pendingSave?.cancel()
    pendingSave = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      save(item)
    }
  }

  /// Leaving the item must not drop the tail of a burst.
  private func flushPendingSave() {
    pendingSave?.cancel()
    pendingSave = nil
    save(item)
  }

  private func save(_ updated: VaultItem) {
    let previous = saveChain
    let revision = editRevision
    let generation = appState.session.sessionGeneration
    saveChain = Task { @MainActor in
      await previous?.value
      // Reloading invalidates old drafts; locking invalidates the session.
      guard revision == editRevision,
        generation == appState.session.sessionGeneration,
        let current = payload, let baseline = lastSaved
      else { return }
      do {
        guard let clean = try current.itemForSaving(updated, replacing: baseline) else { return }
        try await appState.session.mutate(actionName: "Edit Item") { payload in
          payload.updateItem(itemID) { $0 = clean }
        }
        lastSaved = clean
        conflict = nil
        savedAt = Date()
      } catch {
        // The editor banner is the surface for this failure. Repeating it
        // in the window-wide error bar duplicated the message and left it
        // visible after the draft was reloaded.
        conflict = "Save failed: \(error.localizedDescription)"
      }
    }
  }
}

/// One field as a row: label on the left, value taking the rest, options behind
/// a chevron. Sensitive values stay masked until revealed.
struct FieldEditorRow: View {
  @EnvironmentObject var appState: AppState
  @Binding var item: VaultItem
  let fieldID: UUID
  var showsTopDivider: Bool = false

  @State private var reveal = false
  @State private var expanded = false
  @State private var hovered = false
  @State private var customFormat = false
  @State private var aliasesText = ""
  @State private var numberText = ""

  private static let customToken = "__custom__"

  private var fieldIndex: Int? { item.fields.firstIndex(where: { $0.id == fieldID }) }

  private var field: Binding<VaultField>? {
    guard let index = fieldIndex else { return nil }
    let snapshot = item.fields[index]
    // SwiftUI can retain a binding after its row is deleted or moved.
    return Binding(
      get: { item.fields.first(where: { $0.id == fieldID }) ?? snapshot },
      set: { updated in
        guard let index = item.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        item.fields[index] = updated
      })
  }

  private func isRevealable(_ field: VaultField) -> Bool {
    field.type == .secret || field.sensitivity >= .sensitive
  }

  var body: some View {
    if let field {
      VStack(alignment: .leading, spacing: 0) {
        if showsTopDivider { Hairline() }
        row(field)
        if expanded { options(field) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func row(_ field: Binding<VaultField>) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Text(field.wrappedValue.label.isEmpty ? "Untitled field" : field.wrappedValue.label)
        .font(Typography.rowTitle)
        .foregroundStyle(field.wrappedValue.label.isEmpty ? Theme.tertiary : Theme.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: Metrics.labelColumn, alignment: .leading)

      valueArea(field)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        expanded.toggle()
      } label: {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Theme.tertiary)
          .rotationEffect(.degrees(expanded ? 90 : 0))
          .frame(width: 16, height: 16)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .fixedSize()
      .help(expanded ? "Hide field options" : "Show field options")
      .accessibilityLabel("\(field.wrappedValue.label) options")
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
    .padding(.vertical, Metrics.rowVerticalPadding)
    .padding(.horizontal, 6)
    .background(
      hovered ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 5)
    )
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
  }

  @ViewBuilder
  private func valueArea(_ field: Binding<VaultField>) -> some View {
    if isRevealable(field.wrappedValue) && !reveal {
      HStack(spacing: 10) {
        Text(String(repeating: "•", count: 8))
          .font(Typography.value)
          .foregroundStyle(Theme.tertiary)
        Button("Show value") { reveal = true }
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Theme.primary)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Field value")
      .accessibilityValue("Hidden")
    } else {
      editor(for: field.wrappedValue.type, field: field)
    }
  }

  private func options(_ field: Binding<VaultField>) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          MicroLabel("Key")
            .gridColumnAlignment(.trailing)
          TextField("Key", text: field.key)
            .wellField()
            .frame(width: 280)
            .accessibilityLabel("Field key")
            .accessibilityHint("Short identifier, used for search.")
        }

        GridRow {
          MicroLabel("Type")
          Picker(
            "Type",
            selection: Binding(
              get: { field.wrappedValue.type },
              set: { type in
                do {
                  field.wrappedValue = try field.wrappedValue.changingType(to: type)
                  numberText = field.wrappedValue.value.storageDescription
                  reveal = false
                } catch {
                  appState.errorMessage = error.localizedDescription
                }
              })
          ) {
            ForEach(FieldType.allCases, id: \.self) { type in
              Text(type.rawValue).tag(type)
            }
          }
          .labelsHidden()
          .fixedSize()
        }

        GridRow {
          MicroLabel("Sensitivity")
          Picker(
            "Sensitivity",
            selection: Binding(
              get: {
                field.wrappedValue.type == .secret
                  ? max(.sensitive, field.wrappedValue.sensitivity)
                  : field.wrappedValue.sensitivity
              },
              set: { level in
                field.wrappedValue.sensitivity =
                  field.wrappedValue.type == .secret ? max(.sensitive, level) : level
              })
          ) {
            ForEach(
              SensitivityLevel.allCases.filter {
                field.wrappedValue.type != .secret || $0 >= .sensitive
              }, id: \.self
            ) { level in
              Text(level.rawValue).tag(level)
            }
          }
          .labelsHidden()
          .fixedSize()
        }

        GridRow {
          MicroLabel("Aliases")
          VStack(alignment: .leading, spacing: 4) {
            TextField("Comma separated", text: $aliasesText)
              .wellField()
              .frame(width: 280)
              .onChange(of: aliasesText) { _, text in
                if let aliases = CommaSeparatedValues.parse(text) {
                  field.wrappedValue.aliases = aliases
                }
              }
              .accessibilityLabel("Field aliases")
              .accessibilityHint("Quote an alias that contains a comma.")
            if CommaSeparatedValues.parse(aliasesText) == nil {
              Text("Finish the quoted alias to save it.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            }
          }
        }
      }

      HStack(spacing: 2) {
        Button {
          item.moveField(fieldID, by: -1)
        } label: {
          Image(systemName: "arrow.up")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.fields.first?.id == fieldID)
        .accessibilityLabel("Move \(field.wrappedValue.label) up")

        Button {
          item.moveField(fieldID, by: 1)
        } label: {
          Image(systemName: "arrow.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.fields.last?.id == fieldID)
        .accessibilityLabel("Move \(field.wrappedValue.label) down")

        Spacer(minLength: 12)

        Button("Delete Field", role: .destructive) {
          item.fields.removeAll { $0.id == fieldID }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.red)
        .accessibilityLabel("Delete field \(field.wrappedValue.label)")
      }
      .padding(.top, 12)
      .padding(.leading, 76)
    }
    .padding(.leading, 8)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      aliasesText = CommaSeparatedValues.format(field.wrappedValue.aliases)
      numberText = field.wrappedValue.value.storageDescription
    }
  }

  @ViewBuilder
  private func editor(for type: FieldType, field: Binding<VaultField>) -> some View {
    switch type {
    case .text, .email, .url, .phone, .custom:
      TextField(
        "Value",
        text: Binding(
          get: {
            switch field.wrappedValue.value {
            case .text(let v), .email(let v), .url(let v), .phone(let v), .custom(let v): return v
            default: return field.wrappedValue.value.storageDescription
            }
          },
          set: { value in
            switch type {
            case .email: field.wrappedValue.value = .email(value)
            case .url: field.wrappedValue.value = .url(value)
            case .phone: field.wrappedValue.value = .phone(value)
            case .custom: field.wrappedValue.value = .custom(value)
            default: field.wrappedValue.value = .text(value)
            }
          })
      )
      .textFieldStyle(.plain)
      .font(Typography.value)
      .foregroundStyle(Theme.primary)
      .multilineTextAlignment(.leading)
      .lineLimit(1)
      .accessibilityLabel("Field value")

    case .multiline:
      TextEditor(
        text: Binding(
          get: {
            if case .multiline(let v) = field.wrappedValue.value { return v }
            return ""
          },
          set: { field.wrappedValue.value = .multiline($0) })
      )
      .font(Typography.value)
      .scrollContentBackground(.hidden)
      .padding(6)
      .frame(minHeight: 56, maxHeight: 96)
      .background(Theme.well, in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
      .accessibilityLabel("Field value")

    case .secret:
      HStack(spacing: 10) {
        Group {
          if reveal {
            TextField("Value", text: secretBinding(field))
          } else {
            SecureField("Value", text: secretBinding(field))
          }
        }
        .textFieldStyle(.plain)
        .font(Typography.value)
        .foregroundStyle(Theme.primary)

        Button(reveal ? "Hide" : "Show") { reveal.toggle() }
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Theme.primary)
          .accessibilityLabel(reveal ? "Hide value" : "Show value")
      }

    case .number:
      VStack(alignment: .leading, spacing: 3) {
        TextField("Value", text: $numberText)
          .textFieldStyle(.plain)
          .font(Typography.value)
          .foregroundStyle(Theme.primary)
          .accessibilityLabel("Field value")
          .onChange(of: numberText) { _, text in
            if text.isEmpty {
              field.wrappedValue.value = .number(nil)
            } else if let number = Double(text), number.isFinite {
              field.wrappedValue.value = .number(number)
            }
          }
        if !numberText.isEmpty && Double(numberText)?.isFinite != true {
          Text("Enter a finite number. The saved value is unchanged.")
            .font(.caption)
            .foregroundStyle(Theme.secondary)
        }
      }

    case .boolean:
      Toggle(
        "Value",
        isOn: Binding(
          get: {
            if case .boolean(let v) = field.wrappedValue.value { return v }
            return false
          },
          set: { field.wrappedValue.value = .boolean($0) }))
      .toggleStyle(.checkbox)

    case .date:
      VStack(alignment: .leading, spacing: 7) {
        Toggle(
          "Set date",
          isOn: Binding(
            get: {
              if case .date(let value) = field.wrappedValue.value { return value != nil }
              return false
            },
            set: { field.wrappedValue.value = .date($0 ? Date() : nil) }))
        DatePicker(
          "Value",
          selection: Binding(
            get: {
              if case .date(let v) = field.wrappedValue.value { return v ?? Date() }
              return Date()
            },
            set: { field.wrappedValue.value = .date($0) }),
          displayedComponents: .date
        )
        .labelsHidden()
        .disabled(
          {
            if case .date(let value) = field.wrappedValue.value { return value == nil }
            return true
          }())

        Picker("Insert as", selection: formatSelection(field)) {
          ForEach(DateInsertFormat.presets, id: \.value) { preset in
            Text(preset.label).tag(preset.value)
          }
          Text("Custom pattern…").tag(Self.customToken)
        }
        .frame(maxWidth: 280)

        if customFormat
          || !DateInsertFormat.isPreset(
            DateInsertFormat.resolved(field.wrappedValue.preferredInsertFormat))
        {
          TextField(
            "Pattern",
            text: Binding(
              get: { field.wrappedValue.preferredInsertFormat ?? "" },
              set: { field.wrappedValue.preferredInsertFormat = $0 })
          )
          .wellField()
          .frame(width: 280)
          .accessibilityLabel("Custom date pattern")
          .accessibilityHint("A Unicode date format pattern, for example yyyy-MM-dd.")
        }
      }
    }
  }

  private func secretBinding(_ field: Binding<VaultField>) -> Binding<String> {
    Binding(
      get: {
        if case .secret(let v) = field.wrappedValue.value { return v }
        return ""
      },
      set: { field.wrappedValue.value = .secret($0) })
  }

  /// Maps the stored pattern onto the preset list, with a custom escape hatch.
  private func formatSelection(_ field: Binding<VaultField>) -> Binding<String> {
    Binding(
      get: {
        let current = DateInsertFormat.resolved(field.wrappedValue.preferredInsertFormat)
        return !customFormat && DateInsertFormat.isPreset(current) ? current : Self.customToken
      },
      set: { chosen in
        customFormat = chosen == Self.customToken
        if !customFormat { field.wrappedValue.preferredInsertFormat = chosen }
      })
  }
}
