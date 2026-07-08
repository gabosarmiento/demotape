import Carbon.HIToolbox

/// Registers a system-wide hotkey (works while other apps are focused, and the key
/// is consumed so it won't trigger the focused app's own shortcut).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onPressed: (() -> Void)?

    /// Carbon virtual key code + Carbon modifier flags (e.g. cmdKey | shiftKey).
    func register(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let this = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { this.onPressed?() }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x43535254) /* 'CSRT' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
    }
}
