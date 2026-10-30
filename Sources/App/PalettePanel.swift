import AppKit

/// Borderless panel that can take keyboard focus without activating Universal Vault.
/// This keeps the user's field focused in the other app while the palette is open.
final class PalettePanel: NSPanel {
    weak var appState: AppState?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        appState?.dismissPalette()
    }
}
