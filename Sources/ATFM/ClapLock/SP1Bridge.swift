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
    private var programArguments: [String] = []
    private var plistURL: URL?
    /// True while ATFM has unloaded the SP1 LaunchAgent to own detection itself (persisted so a crash can undo it).
    private(set) var daemonSuspended: Bool {
        didSet { UserDefaults.standard.set(daemonSuspended, forKey: Self.suspendedKey) }
    }
    private static let suspendedKey = "sp1DaemonSuspended"
    private(set) var externalProcess: Process?
    var onExternalExit: (() -> Void)?
    /// "jarvis" = SP1's original cinematic HUD, "simple" = plain ATFM/Apple-style lock screens.
    var lockStyle: String {
        didSet { UserDefaults.standard.set(lockStyle, forKey: Self.styleKey) }
    }
    private static let styleKey = "sp1LockStyle"

    private init() {
        lockStyle = UserDefaults.standard.string(forKey: Self.styleKey) ?? "simple"
        daemonSuspended = UserDefaults.standard.bool(forKey: Self.suspendedKey)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var script: URL?
        var app: URL?
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(Self.launchAgentLabel).plist")
        plistURL = FileManager.default.fileExists(atPath: plist.path) ? plist : nil
        if let data = try? Data(contentsOf: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = dict["ProgramArguments"] as? [String] {
            programArguments = args
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

    /// Asks SP1 to lock down now: the daemon (trigger file) if it is running, otherwise a one-shot
    /// `--external` process that locks immediately and quits after the unlock.
    func triggerLockdown() throws {
        guard isInstalled, let triggerFile else {
            throw NSError(domain: "ATFM.SP1", code: 1, userInfo: [NSLocalizedDescriptionKey: "Security-Protocol-1을 찾지 못했어요 (~/\(Self.fallbackDir))"])
        }
        if isRunning() {
            try Date().ISO8601Format().write(to: triggerFile, atomically: true, encoding: .utf8)
        } else {
            try launchExternal()
        }
    }

    var isExternalLockdownActive: Bool { externalProcess?.isRunning ?? false }

    private func launchExternal() throws {
        if let externalProcess, externalProcess.isRunning { return }
        guard let exec = programArguments.first, programArguments.count >= 2 else {
            throw NSError(domain: "ATFM.SP1", code: 2, userInfo: [NSLocalizedDescriptionKey: "SP1 실행 명령을 LaunchAgent에서 읽지 못했어요"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exec)
        process.arguments = Array(programArguments.dropFirst()) + ["--external"]
        process.currentDirectoryURL = baseDir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.externalProcess = nil
                    self?.onExternalExit?()
                }
            }
        }
        try process.run()
        externalProcess = process
    }

    // MARK: Daemon handoff (ATFM owns detection while suspended)

    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func isDaemonLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(Self.launchAgentLabel)"]) == 0
    }

    /// Unloads the SP1 LaunchAgent (KeepAlive would otherwise respawn it) so only ATFM listens.
    func suspendDaemon() {
        guard plistURL != nil else { return }
        _ = launchctl(["bootout", "gui/\(getuid())/\(Self.launchAgentLabel)"])
        daemonSuspended = true
        // Give the process a moment to exit so the trigger path doesn't race it.
        for _ in 0..<15 where isRunning() { usleep(200_000) }
    }

    /// Loads the LaunchAgent again (RunAtLoad starts SP1 immediately).
    func resumeDaemon() {
        guard let plistURL else { daemonSuspended = false; return }
        _ = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        daemonSuspended = false
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
