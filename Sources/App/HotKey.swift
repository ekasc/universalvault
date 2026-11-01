import Foundation
import Carbon
import AppKit
import Core

@MainActor
public final class HotKeyManager {
    public var onPress: (() -> Void)?
    public private(set) var current: HotKeyShortcut = .default
    /// Whether `current` is actually registered with the system. `current` alone
    /// is not enough: a failed registration or a failed restore leaves nothing
    /// registered while `current` still names the last chord that worked.
    public private(set) var isRegistered = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    public init() {}

    isolated deinit {
        // The Carbon handler holds an unretained pointer to self, so it must not
        // outlive it.
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }

    /// Registers `shortcut` as a global hot key.
    ///
    /// Any previously registered shortcut is released first, so a failed
    /// registration leaves the manager with no shortcut rather than a stale one.
    /// Callers that need the old shortcut back must re-register it.
    @discardableResult
    public func register(_ shortcut: HotKeyShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        unregister()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x55564154), id: 1) // "UVAT"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.rawValue,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let registered = ref else { return false }
        hotKeyRef = registered

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let ud = userData else { return noErr }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(ud).takeUnretainedValue()
            Task { @MainActor in mgr.onPress?() }
            return noErr
        }
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType,
                                                Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard handlerStatus == noErr else {
            UnregisterEventHotKey(registered)
            hotKeyRef = nil
            return false
        }

        current = shortcut
        isRegistered = true
        return true
    }

    public func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
        isRegistered = false
    }
}
