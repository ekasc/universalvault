import SwiftUI
import AppKit

/// A panel that can take key input without a titlebar. A borderless window is
/// `canBecomeKey == false` by default, which would leave the search field unable
/// to receive typing.
private final class QuickFillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
public final class PalettePanelController: NSObject, NSWindowDelegate {
    public static weak var shared: PalettePanelController?

    private let panel: NSPanel
    private let appState: AppState
    /// The application that was frontmost when the palette opened. Restoring it
    /// on close is what lets the next Quick Fill capture an external target:
    /// leaving UniversalVault frontmost made every later capture find our own
    /// process and report no target.
    private weak var previousApp: NSRunningApplication?
    /// Milliseconds from `show()` to the panel holding key, for the performance
    /// gate in native verification.
    public private(set) var lastShowMilliseconds: Double = 0
    private var resizeScheduled = false

    public init(appState: AppState) {
        self.appState = appState
        let content = PaletteView().environmentObject(appState)
        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]

        // Borderless with a clear window background: the visible surface, its
        // corner radius, and its hairline are drawn by `PaletteView`, so the
        // window server contributes only the shadow. A titled window would paint
        // a square titlebar over the rounded surface.
        let panel = QuickFillPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: PaletteMetrics.width,
                height: PaletteMetrics.height(fieldCount: 1, empty: false)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = "Quick Fill"
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        // Take key input without waiting for a click. Activation is restored to
        // the previous application in `hide()` so the next capture still sees an
        // external target.
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()
        self.panel = panel
        super.init()
        panel.delegate = self
        PalettePanelController.shared = self
    }

    /// The panel itself, exposed so native verification can screenshot real
    /// window chrome rather than a stand-in window.
    var window: NSWindow { panel }

    /// `restoring` is the application to return to when the palette closes. The
    /// caller knows the captured target; without it the palette would leave
    /// UniversalVault active and the next capture would find no external app.
    public func show(restoring app: NSRunningApplication? = nil) {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = app
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = front
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        resizeToResults(animated: false)
        positionNearMouse()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(panel.contentView)
        lastShowMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    /// Typing changes how many rows match, and the panel is exactly as tall as
    /// those rows. Resizing from the top edge keeps the search field still.
    /// Called from SwiftUI while it is updating, which is inside AppKit's display
    /// cycle. Resizing the window there re-enters layout and AppKit aborts, so the
    /// resize is coalesced and deferred to the next runloop turn.
    public func resultsChanged() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.resizeScheduled else { return }
            self.resizeScheduled = false
            // Instant: an animated window resize per keystroke reads as lag even
            // when the search behind it is fast.
            self.resizeToResults(animated: false)
        }
    }

    private func targetSize() -> NSSize {
        let height = PaletteMetrics.height(
            fieldCount: appState.paletteResults.count,
            empty: appState.paletteResults.isEmpty)
        let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return NSSize(width: PaletteMetrics.width, height: min(height, available - 80))
    }

    private func resizeToResults(animated: Bool) {
        let size = targetSize()
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        frame.size = size
        frame.origin.y = panel.frame.maxY - size.height
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, frame.origin.y)
        }
        panel.setFrame(frame, display: true, animate: animated)
        panel.invalidateShadow()
    }

    public func hide() {
        panel.orderOut(nil)
        if let previousApp,
            previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            !previousApp.isTerminated
        {
            previousApp.activate()
        }
        previousApp = nil
    }

    public func windowWillClose(_ notification: Notification) {
        appState.dismissPalette()
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let f = screen.visibleFrame
            origin.x = max(f.minX, min(origin.x, f.maxX - size.width))
            origin.y = max(f.minY, min(origin.y, f.maxY - size.height))
        }
        panel.setFrameOrigin(origin)
    }
}
