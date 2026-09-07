import AppKit
import Carbon

/// A key + modifier combination, stored as raw values so it round-trips through UserDefaults.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags raw value, masked to ⌘ ⇧ ⌥ ⌃

    static let modifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = flags.intersection(Self.modifierMask).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    /// Global shortcuts need ⌘ / ⌃ / ⌥ (⇧ alone would eat plain typing), or a function key.
    var isUsable: Bool {
        !flags.intersection([.command, .control, .option]).isEmpty || Self.functionKeys.contains(keyCode)
    }

    var display: String { modifierSymbols + Self.keyName(for: keyCode) }

    var modifierSymbols: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    private static let specialNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 71: "⌧", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                    105, 107, 113, 106, 64, 79, 80, 90]

    /// Human-readable key name from the current ASCII-capable keyboard layout (so a Korean input
    /// source still shows the Latin key cap).
    static func keyName(for keyCode: UInt16) -> String {
        if let name = specialNames[keyCode] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "키 \(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "키 \(keyCode)" }
        let name = String(utf16CodeUnits: chars, count: length).uppercased()
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? "키 \(keyCode)" : name
    }
}
