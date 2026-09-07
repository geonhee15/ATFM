import AppKit
import Carbon

struct HotkeyError: Error {
    let status: OSStatus
    var message: String {
        status == OSStatus(eventHotKeyExistsErr) ? "다른 앱이 이미 쓰고 있는 단축키예요" : "단축키 등록 실패 (\(status))"
    }
}

/// System-wide hotkeys through Carbon's RegisterEventHotKey — works from a menu-bar app without
/// Accessibility access and fires even when another app is frontmost.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x4154_464D   // 'ATFM'

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, userData, &handler)
    }

    func register(_ combo: KeyCombo, action: @escaping () -> Void) -> Result<UInt32, HotkeyError> {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return .failure(HotkeyError(status: status)) }
        refs[id] = ref
        actions[id] = action
        return .success(id)
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
    }
}
