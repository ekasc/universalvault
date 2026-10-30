import Foundation
import Carbon
import AppKit

@MainActor
public final class HotKeyManager {
    public var onPress: (() -> Void)?
    public private(set) var isRegistered = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    public init() {}

    public func register(keyCode: UInt32 = UInt32(kVK_ANSI_V), modifiers: UInt32 = UInt32(controlKey | optionKey)) -> Bool {
        unregister()
        let gMyHotKeyID = EventHotKeyID(signature: OSType(0x55564154), id: 1) // UVAT
        let status = RegisterEventHotKey(keyCode, modifiers, gMyHotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            isRegistered = false
            return false
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let ud = userData else { return noErr }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(ud).takeUnretainedValue()
            Task { @MainActor in mgr.onPress?() }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let hStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &eventHandler)
        isRegistered = hStatus == noErr
        return isRegistered
    }

    public func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
        isRegistered = false
    }
}
