import AppKit
import Observation
import UserNotifications

/// Stopwatch + countdown timer. Time is derived from Dates so it keeps running while the bubble is
/// closed; the countdown also shows in the menu bar and rings a sound / notification / HUD when done.
@MainActor
@Observable
final class TimerCenter {
    // MARK: Stopwatch

    private(set) var stopwatchStartedAt: Date?
    private(set) var stopwatchAccumulated: TimeInterval = 0
    private(set) var laps: [TimeInterval] = []          // cumulative times

    var stopwatchRunning: Bool { stopwatchStartedAt != nil }

    func stopwatchElapsed(at now: Date = Date()) -> TimeInterval {
        stopwatchAccumulated + (stopwatchStartedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    func stopwatchToggle() {
        if let started = stopwatchStartedAt {
            stopwatchAccumulated += Date().timeIntervalSince(started)
            stopwatchStartedAt = nil
        } else {
            stopwatchStartedAt = Date()
        }
    }

    func stopwatchLap() {
        guard stopwatchRunning else { return }
        laps.append(stopwatchElapsed())
    }

    func stopwatchReset() {
        stopwatchStartedAt = nil
        stopwatchAccumulated = 0
        laps = []
    }

    // MARK: Countdown

    private(set) var duration: TimeInterval {
        didSet { UserDefaults.standard.set(duration, forKey: Self.durationKey) }
    }
    private(set) var endsAt: Date?
    private(set) var pausedRemaining: TimeInterval?
    private(set) var finishedAt: Date?
    var showInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: Self.menuBarKey)
            refreshMenuBar()
        }
    }
    private(set) var menuBarText: String?
    private(set) var notificationsAllowed: Bool?

    /// Shown at the top edge when the countdown ends (AppDelegate wires this to the HUD).
    @ObservationIgnored var onFinished: ((String) -> Void)?
    @ObservationIgnored private var finishTimer: Timer?
    @ObservationIgnored private var tickTimer: Timer?

    private static let durationKey = "timerDuration"
    private static let menuBarKey = "timerMenuBar"
    static let presets: [Int] = [1, 3, 5, 10, 15, 25, 30, 60]   // minutes

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.durationKey)
        duration = stored > 0 ? stored : 300
        showInMenuBar = UserDefaults.standard.object(forKey: Self.menuBarKey) as? Bool ?? true
    }

    var timerRunning: Bool { endsAt != nil }
    var timerPaused: Bool { pausedRemaining != nil }
    var timerFinished: Bool { finishedAt != nil }

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        if let pausedRemaining { return pausedRemaining }
        return timerFinished ? 0 : duration
    }

    func setDuration(_ seconds: TimeInterval) {
        guard !timerRunning else { return }
        duration = max(1, min(seconds, 99 * 3600))
        pausedRemaining = nil
        finishedAt = nil
    }

    func startTimer() {
        let seconds = pausedRemaining ?? duration
        guard seconds > 0 else { return }
        finishedAt = nil
        pausedRemaining = nil
        endsAt = Date().addingTimeInterval(seconds)
        scheduleFinish()
        startTicking()
        requestNotificationsIfNeeded()
        refreshMenuBar()
    }

    func pauseTimer() {
        guard let endsAt else { return }
        pausedRemaining = max(0, endsAt.timeIntervalSince(Date()))
        self.endsAt = nil
        finishTimer?.invalidate()
        finishTimer = nil
        refreshMenuBar()
    }

    func resetTimer() {
        endsAt = nil
        pausedRemaining = nil
        finishedAt = nil
        finishTimer?.invalidate()
        finishTimer = nil
        stopTicking()
        refreshMenuBar()
    }

    func addMinute() {
        if let endsAt {
            self.endsAt = endsAt.addingTimeInterval(60)
            scheduleFinish()
        } else if let pausedRemaining {
            self.pausedRemaining = pausedRemaining + 60
        } else {
            setDuration(duration + 60)
        }
        refreshMenuBar()
    }

    private func scheduleFinish() {
        finishTimer?.invalidate()
        guard let endsAt else { return }
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        finishTimer = timer
    }

    private func finish() {
        let total = duration
        endsAt = nil
        pausedRemaining = nil
        finishedAt = Date()
        finishTimer = nil
        stopTicking()
        refreshMenuBar()
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { NSSound(named: "Glass")?.play() }
        let label = Self.format(total, showFraction: false)
        onFinished?("타이머 종료 · \(label)")
        postNotification(label: label)
    }

    // MARK: Menu bar text (ticks once a second only while counting down)

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenuBar() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        refreshMenuBar()
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func refreshMenuBar() {
        guard showInMenuBar, endsAt != nil || pausedRemaining != nil else {
            menuBarText = nil
            return
        }
        let text = Self.format(remaining(), showFraction: false)
        menuBarText = pausedRemaining != nil ? "❚❚ \(text)" : text
    }

    // MARK: Notifications

    private func requestNotificationsIfNeeded() {
        guard notificationsAllowed == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.notificationsAllowed = granted } }
        }
    }

    private func postNotification(label: String) {
        let content = UNMutableNotificationContent()
        content.title = "타이머 종료"
        content.body = "\(label) 타이머가 끝났어요."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "atfm.timer.\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Formatting

    static func format(_ seconds: TimeInterval, showFraction: Bool) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        let base = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
        guard showFraction else { return base }
        let hundredths = Int((clamped - Double(total)) * 100)
        return base + String(format: ".%02d", hundredths)
    }
}
