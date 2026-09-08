import AppKit
import Observation

/// One running app that might be worth quitting.
struct CleanupCandidate: Identifiable {
    let id: String              // bundle identifier (falls back to the executable path)
    let name: String
    let bundlePath: String?
    let pid: pid_t
    var cpuPercent: Double
    var memoryBytes: UInt64
    var networkRate: Double     // bytes per second in + out
    var windowCount: Int        // on-screen, normal-layer windows
    var isFrontmost: Bool
    var isPlayingMedia: Bool
    var reasons: [String]
    var suggested: Bool
    var isProtected: Bool
    var selected: Bool

    var impactScore: Double {
        cpuPercent * 20 + Double(memoryBytes) / (50 * 1024 * 1024) + networkRate / (50 * 1024)
    }
}

/// Finds Dock apps that burn CPU / memory / network in the background and quits the ones the user picks.
@MainActor
@Observable
final class AppCleaner {
    enum Phase: Equatable {
        case idle, scanning, ready, quitting
        case done(quit: Int, stillRunning: Int)
    }

    private(set) var phase: Phase = .idle
    private(set) var candidates: [CleanupCandidate] = []
    private(set) var lastScan: Date?
    var forceQuit: Bool {
        didSet { UserDefaults.standard.set(forceQuit, forKey: Self.forceKey) }
    }
    private(set) var protectedIDs: Set<String>

    /// Re-applies the tab-driven monitor state after a scan (AppState.updateMonitors).
    @ObservationIgnored var restoreMonitors: (() -> Void)?
    /// Bundle ID of the app currently playing media, if any (never suggested).
    @ObservationIgnored var playingBundleID: (() -> String?)?

    @ObservationIgnored private let sampler: ProcessSampler
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private var scanToken = 0

    private static let forceKey = "cleanupForceQuit"
    private static let protectedKey = "cleanupProtectedApps"
    static let scanSeconds = 3.0

    // Thresholds for "이 앱, 지금 꼭 필요한가?"
    private static let cpuHeavy = 4.0                  // % of the whole machine
    private static let memoryHeavy: UInt64 = 600 << 20
    private static let memoryIdle: UInt64 = 250 << 20  // no windows + this much memory → suggested
    private static let networkHeavy = 100.0 * 1024     // bytes/s

    init(resolver: ProcessIdentityResolver, network: NetworkMonitor) {
        sampler = ProcessSampler(resolver: resolver)
        self.network = network
        forceQuit = UserDefaults.standard.bool(forKey: Self.forceKey)
        protectedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.protectedKey) ?? [])
    }

    var selectedCount: Int { candidates.filter(\.selected).count }
    var suggestedCount: Int { candidates.filter(\.suggested).count }

    // MARK: Scan

    func scan() {
        guard phase != .scanning else { return }
        phase = .scanning
        scanToken += 1
        let token = scanToken
        _ = sampler.sample()                       // prime CPU counters
        let networkWasActive = network.isActive
        if !networkWasActive { network.setActive(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scanToken == token else { return }
                self.finishScan(networkWasActive: networkWasActive)
            }
        }
    }

    private func finishScan(networkWasActive: Bool) {
        let usage = sampler.sample()
        let traffic = network.apps
        if !networkWasActive { restoreMonitors?() ?? network.setActive(false) }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let playing = playingBundleID?()
        let windows = Self.windowCounts()
        let selfID = Bundle.main.bundleIdentifier
        let neverQuit: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", selfID ?? ""]

        var list: [CleanupCandidate] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isTerminated else { continue }
            let bundleID = app.bundleIdentifier ?? app.executableURL?.path ?? "pid-\(app.processIdentifier)"
            guard !neverQuit.contains(bundleID) else { continue }
            let path = app.bundleURL?.path
            let use = usage.first { ($0.bundleID != nil && $0.bundleID == app.bundleIdentifier) || ($0.bundlePath != nil && $0.bundlePath == path) }
            let net = traffic.first { $0.bundlePath != nil && $0.bundlePath == path }
            let cpu = use?.cpuPercent ?? 0
            let memory = use?.memoryBytes ?? 0
            let rate = net?.totalRate ?? 0
            let windowCount = windows[app.processIdentifier] ?? 0
            let isFrontmost = bundleID == frontmost
            let isPlaying = playing != nil && playing == app.bundleIdentifier
            let isProtected = protectedIDs.contains(bundleID)

            var reasons: [String] = []
            if cpu >= Self.cpuHeavy { reasons.append("CPU \(Int(cpu.rounded()))%") }
            if rate >= Self.networkHeavy { reasons.append("네트워크 \(Format.bytes(UInt64(rate)))/s") }
            if app.isHidden { reasons.append("숨김") } else if windowCount == 0 { reasons.append("창 없음") }
            let inBackground = app.isHidden || windowCount == 0
            let memoryHeavy = memory >= Self.memoryHeavy
            let idleButHeavy = inBackground && (memory >= Self.memoryIdle || cpu >= 2)
            guard !reasons.isEmpty || memoryHeavy || idleButHeavy else { continue }   // only apps worth a look
            // Suggest only what looks wasteful: background apps that still burn CPU / network / RAM.
            // A memory-hungry app with a window on screen is listed but left unchecked.
            var suggested = !isFrontmost && !isPlaying && !isProtected
            if suggested {
                suggested = cpu >= Self.cpuHeavy || rate >= Self.networkHeavy || idleButHeavy
            }
            if isFrontmost { reasons.insert("지금 사용 중", at: 0) }
            if isPlaying { reasons.insert("재생 중", at: 0) }
            list.append(CleanupCandidate(id: bundleID, name: app.localizedName ?? bundleID, bundlePath: path,
                                         pid: app.processIdentifier, cpuPercent: cpu, memoryBytes: memory,
                                         networkRate: rate, windowCount: windowCount, isFrontmost: isFrontmost,
                                         isPlayingMedia: isPlaying, reasons: reasons, suggested: suggested,
                                         isProtected: isProtected, selected: suggested))
        }
        candidates = list.sorted { $0.impactScore > $1.impactScore }
        lastScan = Date()
        phase = .ready
    }

    /// On-screen window count per owner PID (window metadata needs no Screen Recording access).
    private static func windowCounts() -> [pid_t: Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var counts: [pid_t: Int] = [:]
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 50, (bounds["Height"] ?? 0) >= 50 else { continue }
            counts[pid, default: 0] += 1
        }
        return counts
    }

    // MARK: Selection / protection

    func toggleSelected(_ id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].selected.toggle()
    }

    func toggleProtected(_ id: String) {
        if protectedIDs.contains(id) { protectedIDs.remove(id) } else { protectedIDs.insert(id) }
        UserDefaults.standard.set(Array(protectedIDs).sorted(), forKey: Self.protectedKey)
        if let index = candidates.firstIndex(where: { $0.id == id }) {
            candidates[index].isProtected = protectedIDs.contains(id)
            if candidates[index].isProtected { candidates[index].selected = false }
        }
    }

    func selectAllSuggested() {
        for index in candidates.indices { candidates[index].selected = candidates[index].suggested && !candidates[index].isProtected }
    }

    func reset() {
        scanToken += 1
        phase = .idle
        candidates = []
    }

    // MARK: Quit

    func quitSelected() {
        let targets = candidates.filter { $0.selected && !$0.isProtected }
        guard !targets.isEmpty else { return }
        phase = .quitting
        var apps: [NSRunningApplication] = []
        for target in targets {
            guard let app = NSRunningApplication(processIdentifier: target.pid) else { continue }
            apps.append(app)
            if forceQuit { app.forceTerminate() } else { app.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stillRunning = apps.filter { !$0.isTerminated }
                let quit = apps.count - stillRunning.count
                let remaining = Set(stillRunning.map(\.processIdentifier))
                self.candidates.removeAll { !remaining.contains($0.pid) && $0.selected && !$0.isProtected }
                for index in self.candidates.indices where remaining.contains(self.candidates[index].pid) {
                    self.candidates[index].selected = false
                    if !self.candidates[index].reasons.contains("종료 대기 중") { self.candidates[index].reasons.insert("종료 대기 중", at: 0) }
                }
                self.phase = .done(quit: quit, stillRunning: stillRunning.count)
            }
        }
    }
}
