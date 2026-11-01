import SwiftUI
import Core

/// The one place a "there is nothing here" state is drawn, so vault/empty
/// states stay consistent and announced the same way.
struct VaultPlaceholder: View {
    let symbol: String
    let title: String
    var message: String?
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.emptyTitle)
                .foregroundStyle(Theme.primary)
            if let message {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Icon choices offered for an item. Free-text SF Symbol names would let a user
/// type a name that renders as nothing.
enum ItemIcon {
    static let presets = [
        "doc.text", "person.text.rectangle", "creditcard", "book.closed",
        "car", "graduationcap", "briefcase", "mappin.and.ellipse",
        "key", "lock", "envelope", "phone", "building.2", "heart.text.square",
    ]

    static let fallback = "doc.text"

    static func symbol(for item: VaultItem) -> String {
        guard let icon = item.icon, !icon.isEmpty else { return fallback }
        return icon
    }
}
