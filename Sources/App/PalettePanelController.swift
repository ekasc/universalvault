import SwiftUI
import AppKit

@MainActor
public final class PalettePanelController {
    public static weak var shared: PalettePanelController?

    private let panel: NSPanel
    private let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
        let content = PaletteView().environmentObject(appState)
        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Quick Fill"
        panel.contentView = hosting
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.center()
        self.panel = panel
        PalettePanelController.shared = self
    }

    public func show() {
        FileHandle.standardError.write(Data("SHOW\n".utf8))
        positionNearMouse()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(panel.contentView)
    }

    public func hide() {
        panel.orderOut(nil)
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - 260, y: mouse.y - 210)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - 520)
            origin.y = min(max(origin.y, f.minY), f.maxY - 420)
        }
        panel.setFrameOrigin(origin)
    }
}
