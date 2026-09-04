import AppKit
import IOKit.pwr_mgt
import Observation

enum AwakeDuration: Int, CaseIterable, Identifiable {
    case forever = 0
    case minutes30 = 30
    case hour1 = 60
    case hours2 = 120
    case hours4 = 240
    case hours8 = 480

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .forever: return "계속"
        case .minutes30: return "30분"
        case .hour1: return "1시간"
        case .hours2: return "2시간"
        case .hours4: return "4시간"
        case .hours8: return "8시간"
        }
    }
}

/// Keeps the Mac (and optionally the display) awake with IOKit power assertions.
@MainActor
@Observable
final class KeepAwake {
    var isActive = false
    var duration: AwakeDuration
    var keepDisplayOn: Bool
    var startedAt: Date?
    var endsAt: Date?
    var now = Date()
    var lidSleepDisabled = false
    var lidError: String?

    @ObservationIgnored private var assertions: [IOPMAssertionID] = []
    @ObservationIgnored private var timer: Timer?
    private static let durationKey = "awakeDuration"
    private static let displayKey = "awakeKeepDisplayOn"

    init() {
        let defaults = UserDefaults.standard
        duration = AwakeDuration(rawValue: defaults.integer(forKey: Self.durationKey)) ?? .forever
        keepDisplayOn = (defaults.object(forKey: Self.displayKey) as? Bool) ?? true
    }

    var remainingText: String? {
        guard isActive else { return nil }
        guard let endsAt else { return "계속 깨어 있음" }
        let seconds = max(0, Int(endsAt.timeIntervalSince(now)))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)시간 \(m)분 남음" }
        if m > 0 { return "\(m)분 \(s)초 남음" }
        return "\(s)초 남음"
    }

    // MARK: Control

    func setActive(_ on: Bool) {
        if on { start() } else { stop() }
    }

    func setDuration(_ value: AwakeDuration) {
        duration = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.durationKey)
        if isActive { start() }   // restart with the new deadline
    }

    func setKeepDisplayOn(_ on: Bool) {
        keepDisplayOn = on
        UserDefaults.standard.set(on, forKey: Self.displayKey)
        if isActive { start() }
    }

    private func start() {
        releaseAssertions()
        var ids: [IOPMAssertionID] = []
        var id: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "ATFM Keep Awake" as CFString, &id) == kIOReturnSuccess {
            ids.append(id)
        }
        if keepDisplayOn {
            var displayID: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "ATFM Keep Awake (display)" as CFString, &displayID) == kIOReturnSuccess {
                ids.append(displayID)
            }
        }
        assertions = ids
        isActive = !ids.isEmpty
        startedAt = Date()
        endsAt = duration == .forever ? nil : Date().addingTimeInterval(TimeInterval(duration.rawValue * 60))
        now = Date()
        startTimer()
    }

    private func stop() {
        releaseAssertions()
        isActive = false
        startedAt = nil
        endsAt = nil
        timer?.invalidate()
        timer = nil
    }

    private func releaseAssertions() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions = []
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        now = Date()
        if let endsAt, now >= endsAt { stop() }
    }

    // MARK: Lid (pmset disablesleep, needs admin)

    func refreshLidState() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.first == "SleepDisabled", let value = parts.last {
                lidSleepDisabled = value == "1"
                return
            }
        }
        lidSleepDisabled = false
    }

    func setLidSleepDisabled(_ disabled: Bool) {
        lidError = nil
        let command = "pmset -a disablesleep \(disabled ? 1 : 0)"
        let source = "do shell script \"\(command)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code != -128 {   // -128 = user cancelled
                lidError = error[NSAppleScript.errorMessage] as? String ?? "변경하지 못했어요"
            }
        }
        refreshLidState()
    }
}
