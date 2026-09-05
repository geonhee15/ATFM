import AppKit
import Darwin

/// Talks to the user's Security-Protocol-1 daemon: trigger its lockdown, launch it, hand it a theme.
@MainActor
final class SP1Bridge {
    static let shared = SP1Bridge()
    static let launchAgentLabel = "com.geonhee.security-protocol-1"
    private static let fallbackDir = "Desktop/Important/Security-Protocol-1"

    let baseDir: URL?
    let scriptURL: URL?
    let appURL: URL?
    /// "jarvis" = SP1's original cinematic HUD, "simple" = plain ATFM/Apple-style lock screens.
    var lockStyle: String {
        didSet { UserDefaults.standard.set(lockStyle, forKey: Self.styleKey) }
    }
    private static let styleKey = "sp1LockStyle"

    private init() {
        lockStyle = UserDefaults.standard.string(forKey: Self.styleKey) ?? "simple"
        let home = FileManager.default.homeDirectoryForCurrentUser
        var script: URL?
        var app: URL?
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(Self.launchAgentLabel).plist")
        if let data = try? Data(contentsOf: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = dict["ProgramArguments"] as? [String] {
            if let scriptPath = args.first(where: { $0.hasSuffix("security_protocol.py") }) {
                script = URL(fileURLWithPath: scriptPath)
            }
            if let exec = args.first, let range = exec.range(of: ".app/") {
                app = URL(fileURLWithPath: String(exec[..<range.lowerBound]) + ".app")
            }
        }
        if script == nil {
            let candidate = home.appendingPathComponent(Self.fallbackDir).appendingPathComponent("security_protocol.py")
            if FileManager.default.fileExists(atPath: candidate.path) { script = candidate }
        }
        scriptURL = script
        baseDir = script?.deletingLastPathComponent()
        if app == nil, let baseDir {
            let bundled = baseDir.appendingPathComponent("SecurityProtocol1.app")
            if FileManager.default.fileExists(atPath: bundled.path) { app = bundled }
        }
        appURL = app
    }

    var isInstalled: Bool {
        guard let scriptURL else { return false }
        return FileManager.default.fileExists(atPath: scriptURL.path)
    }

    private var lockFile: URL? { baseDir?.appendingPathComponent(".security_protocol.lock") }
    private var triggerFile: URL? { baseDir?.appendingPathComponent(".sp1-trigger") }
    private var themeFile: URL? { baseDir?.appendingPathComponent("theme.json") }

    /// The daemon writes its pid into the lock file and keeps an flock on it while alive.
    func isRunning() -> Bool {
        guard let lockFile, let text = try? String(contentsOf: lockFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Asks SP1 to lock down now; starts it first if it is not running.
    func triggerLockdown() throws {
        guard isInstalled, let triggerFile else {
            throw NSError(domain: "ATFM.SP1", code: 1, userInfo: [NSLocalizedDescriptionKey: "Security-Protocol-1을 찾지 못했어요 (~/\(Self.fallbackDir))"])
        }
        try Date().ISO8601Format().write(to: triggerFile, atomically: true, encoding: .utf8)
        if !isRunning() { launch() }
    }

    func launch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.launchAgentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0, let appURL {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Exports the ATFM theme so SP1's lockdown HUD and UNLOCK button use the same palette.
    func writeTheme(_ theme: AppTheme) {
        guard isInstalled, let themeFile else { return }
        var payload = theme.sp1Theme
        payload["style"] = lockStyle
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: themeFile, options: .atomic)
        }
    }
}
