import AppKit
import Darwin

private let RTLD_DEFAULT_HANDLE = UnsafeMutableRawPointer(bitPattern: -2)

// MARK: - Keyboard backlight (CoreBrightness private API)

final class KeyboardBacklight {
    private typealias GetFloat = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFloat = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private let client: NSObject?
    private let keyboardID: UInt64?
    private let msgSend: UnsafeMutableRawPointer?

    init() {
        var client: NSObject?
        var keyboardID: UInt64?
        if dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
           let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let object = cls.init()
            // Method name differs across macOS versions; try both, then fall back to probing IDs.
            for name in ["copyKeyboardBacklightIDs", "copyKeyboardBackgroundServiceIDs"] {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { continue }
                if let ids = object.perform(selector)?.takeRetainedValue() as? [NSNumber], let first = ids.first {
                    keyboardID = first.uint64Value
                    break
                }
            }
            if keyboardID == nil, let send = dlsym(RTLD_DEFAULT_HANDLE, "objc_msgSend") {
                typealias BoolForID = @convention(c) (AnyObject, Selector, UInt64) -> Bool
                let isBuiltIn = unsafeBitCast(send, to: BoolForID.self)
                for candidate: UInt64 in 1...4 where isBuiltIn(object, NSSelectorFromString("isKeyboardBuiltIn:"), candidate) {
                    keyboardID = candidate
                    break
                }
            }
            client = object
        }
        self.client = client
        self.keyboardID = keyboardID
        msgSend = dlsym(RTLD_DEFAULT_HANDLE, "objc_msgSend")
    }

    var isAvailable: Bool { client != nil && keyboardID != nil && msgSend != nil }

    var brightness: Float? {
        guard let client, let keyboardID, let msgSend else { return nil }
        let fn = unsafeBitCast(msgSend, to: GetFloat.self)
        return fn(client, NSSelectorFromString("brightnessForKeyboard:"), keyboardID)
    }

    @discardableResult
    func setBrightness(_ value: Float) -> Bool {
        guard let client, let keyboardID, let msgSend else { return false }
        let fn = unsafeBitCast(msgSend, to: SetFloat.self)
        return fn(client, NSSelectorFromString("setBrightness:forKeyboard:"), min(1, max(0, value)), keyboardID)
    }
}

// MARK: - Screen lock / saver / display

enum ScreenControl {
    private typealias LockFn = @convention(c) () -> Int32

    static var canLock: Bool { lockSymbol() != nil }

    private static func lockSymbol() -> UnsafeMutableRawPointer? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW) else { return nil }
        return dlsym(handle, "SACLockScreenImmediate")
    }

    /// Same as ⌃⌘Q: goes straight to the lock screen (password prompt).
    static func lockScreen() throws {
        if let symbol = lockSymbol() {
            let fn = unsafeBitCast(symbol, to: LockFn.self)
            _ = fn()
            return
        }
        // Fallback: fast-user-switch to the login window.
        try Shell.run("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"])
    }

    static func startScreenSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("ATFM: screensaver failed: \(error)") }
        }
    }

    static func sleepDisplay() throws {
        try Shell.run("/usr/bin/pmset", ["displaysleepnow"])
    }
}

// MARK: - Finder preferences

enum FinderPrefs {
    private static let domain = "com.apple.finder"

    static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = UserDefaults(suiteName: domain)?.object(forKey: key) else { return defaultValue }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
        return defaultValue
    }

    static func set(_ key: String, _ value: Bool) {
        let defaults = UserDefaults(suiteName: domain)
        defaults?.set(value, forKey: key)
        defaults?.synchronize()
    }

    static func restartFinder() throws {
        try Shell.run("/usr/bin/killall", ["Finder"])
    }

    static var showsHiddenFiles: Bool { bool("AppleShowAllFiles", default: false) }
    static var desktopIconsVisible: Bool { bool("CreateDesktop", default: true) }
}

// MARK: - Trash & volumes

enum TrashInfo {
    static var itemCount: Int? {
        let path = NSHomeDirectory() + "/.Trash"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return items.filter { $0 != ".DS_Store" }.count
    }

    /// Asks Finder so items on external volumes and "Put Back" metadata are handled properly.
    static func empty() throws {
        guard let script = NSAppleScript(source: "tell application \"Finder\" to empty trash") else {
            throw QuickActionError.message("AppleScript를 만들 수 없어요")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Finder가 거부했어요"
            throw QuickActionError.message(message)
        }
    }
}

enum Volumes {
    private static let keys: [URLResourceKey] = [
        .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsEjectableKey,
        .volumeIsRemovableKey, .volumeIsLocalKey, .volumeLocalizedNameKey,
    ]

    static func external() -> [URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            if values.volumeIsRootFileSystem == true { return false }
            if values.volumeIsEjectable == true || values.volumeIsRemovable == true { return true }
            return values.volumeIsInternal == false && values.volumeIsLocal == true
        }
    }

    static func ejectAll() throws -> Int {
        var ejected = 0
        var failures: [String] = []
        for url in external() {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                ejected += 1
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        if !failures.isEmpty {
            throw QuickActionError.message("추출 실패: " + failures.joined(separator: ", "))
        }
        return ejected
    }
}

// MARK: - Helpers

enum QuickActionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

enum Shell {
    static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw QuickActionError.message("\((path as NSString).lastPathComponent) 실패 (\(process.terminationStatus))")
        }
    }
}
