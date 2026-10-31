import AppKit
import ApplicationServices
import Observation

/// 오토클릭: posts mouse clicks at a fixed interval (follow the pointer or a fixed point) until stopped,
/// a count is reached or a duration passes. Needs 손쉬운 사용 (Accessibility) to deliver clicks to other apps.
@MainActor
@Observable
final class AutoClicker {
    enum MouseButton: String, CaseIterable, Identifiable {
        case left, right, middle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .left: return "왼쪽"
            case .right: return "오른쪽"
            case .middle: return "가운데"
            }
        }
        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }
        var downType: CGEventType {
            switch self {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .middle: return .otherMouseDown
            }
        }
        var upType: CGEventType {
            switch self {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .middle: return .otherMouseUp
            }
        }
    }

    enum ClickType: String, CaseIterable, Identifiable {
        case single, double
        var id: String { rawValue }
        var title: String { self == .single ? "한 번" : "두 번" }
    }

    enum PositionMode: String, CaseIterable, Identifiable {
        case follow, fixed
        var id: String { rawValue }
        var title: String { self == .follow ? "마우스 따라가기" : "고정 위치" }
    }

    enum RepeatMode: String, CaseIterable, Identifiable {
        case forever, count, duration
        var id: String { rawValue }
        var title: String {
            switch self {
            case .forever: return "멈출 때까지"
            case .count: return "횟수"
            case .duration: return "시간"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case countdown(Int)        // seconds left before the first click
        case running
    }

    // Settings (persisted)
    var intervalMs: Double { didSet { save() } }
    var jitterPercent: Double { didSet { save() } }
    var button: MouseButton { didSet { save() } }
    var clickType: ClickType { didSet { save() } }
    var positionMode: PositionMode { didSet { save() } }
    var fixedPoint: CGPoint { didSet { save() } }
    var repeatMode: RepeatMode { didSet { save() } }
    var repeatCount: Int { didSet { save() } }
    var durationSeconds: Double { didSet { save() } }
    var startDelay: Int { didSet { save() } }
    var stopOnMove: Bool { didSet { save() } }

    // State
    private(set) var phase: Phase = .idle
    private(set) var clickCount = 0
    private(set) var startedAt: Date?
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastStopReason: String?
    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private(set) var captureCountdown: Int?
    private(set) var isDryRun = false

    @ObservationIgnored var notify: ((String, String) -> Void)?
    @ObservationIgnored private let queue = DispatchQueue(label: "atfm.autoclick", qos: .userInteractive)
    @ObservationIgnored private var run: ClickRun?
    @ObservationIgnored private var uiTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var escMonitors: [Any] = []
    @ObservationIgnored private var deadline: Date?
    @ObservationIgnored private var limit: Int?
    @ObservationIgnored private var source = CGEventSource(stateID: .hidSystemState)

    var isRunning: Bool { if case .running = phase { return true } else { return false } }
    var isActive: Bool { phase != .idle }
    var clicksPerSecond: Double { intervalMs > 0 ? 1000 / intervalMs : 0 }

    init() {
        let d = UserDefaults.standard
        let storedInterval = d.double(forKey: "autoClickInterval")
        intervalMs = storedInterval > 0 ? storedInterval : 100
        jitterPercent = d.double(forKey: "autoClickJitter")
        button = MouseButton(rawValue: d.string(forKey: "autoClickButton") ?? "") ?? .left
        clickType = ClickType(rawValue: d.string(forKey: "autoClickType") ?? "") ?? .single
        positionMode = PositionMode(rawValue: d.string(forKey: "autoClickPosition") ?? "") ?? .follow
        fixedPoint = CGPoint(x: d.double(forKey: "autoClickPointX"), y: d.double(forKey: "autoClickPointY"))
        repeatMode = RepeatMode(rawValue: d.string(forKey: "autoClickRepeat") ?? "") ?? .forever
        let storedCount = d.integer(forKey: "autoClickCount")
        repeatCount = storedCount > 0 ? storedCount : 100
        let storedDuration = d.double(forKey: "autoClickDuration")
        durationSeconds = storedDuration > 0 ? storedDuration : 30
        startDelay = d.object(forKey: "autoClickDelay") as? Int ?? 3
        stopOnMove = d.object(forKey: "autoClickStopOnMove") as? Bool ?? true
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(intervalMs, forKey: "autoClickInterval")
        d.set(jitterPercent, forKey: "autoClickJitter")
        d.set(button.rawValue, forKey: "autoClickButton")
        d.set(clickType.rawValue, forKey: "autoClickType")
        d.set(positionMode.rawValue, forKey: "autoClickPosition")
        d.set(Double(fixedPoint.x), forKey: "autoClickPointX")
        d.set(Double(fixedPoint.y), forKey: "autoClickPointY")
        d.set(repeatMode.rawValue, forKey: "autoClickRepeat")
        d.set(repeatCount, forKey: "autoClickCount")
        d.set(durationSeconds, forKey: "autoClickDuration")
        d.set(startDelay, forKey: "autoClickDelay")
        d.set(stopOnMove, forKey: "autoClickStopOnMove")
    }

    // MARK: Permission

    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var tabVisible = false

    func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            if trusted { notify?("오토클릭", "손쉬운 사용 권한이 확인됐어요") }
        }
        updatePermissionWatch()
    }

    /// While the tab is open and the permission is missing, re-check every second so flipping the
    /// switch in System Settings is picked up without reopening the bubble.
    func setTabVisible(_ visible: Bool) {
        tabVisible = visible
        if visible { refreshPermission() } else { updatePermissionWatch() }
    }

    private func updatePermissionWatch() {
        let wanted = tabVisible && !accessibilityTrusted
        if wanted, permissionTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        } else if !wanted {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    /// The reset command for the stuck case (an entry that belongs to an older copy of the app).
    static let resetCommand = "tccutil reset Accessibility com.geonhee.atfm"

    func copyResetCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.resetCommand, forType: .string)
        notify?("복사됨", Self.resetCommand)
    }

    func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Shows the system prompt (adds ATFM to the Accessibility list, unchecked) — only from a user tap.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Start / stop

    /// Hotkey: toggles immediately (no countdown — the pointer is already where the user wants it).
    func toggle() {
        if isActive { stop(reason: "단축키로 정지") } else { begin(delay: 0, dryRun: false) }
    }

    /// Button in the bubble: counts down first so the user can move to the target window.
    func startFromPanel() {
        begin(delay: startDelay, dryRun: false)
    }

    /// Development/screenshots: same loop, nothing is posted.
    func startDryRun() {
        begin(delay: 0, dryRun: true)
    }

    private func begin(delay: Int, dryRun: Bool) {
        guard !isActive else { return }
        refreshPermission()
        if !dryRun && !accessibilityTrusted {
            lastStopReason = "손쉬운 사용 권한이 없어서 클릭을 보낼 수 없어요"
            notify?("오토클릭", "손쉬운 사용 권한이 필요해요")
            return
        }
        isDryRun = dryRun
        lastStopReason = nil
        clickCount = 0
        elapsed = 0
        run = nil
        if delay > 0 {
            phase = .countdown(delay)
            notify?("오토클릭", "\(delay)초 뒤 시작 · \(intervalText)")
            var remaining = delay
            countdownTimer?.invalidate()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, case .countdown = self.phase else { timer.invalidate(); return }
                    remaining -= 1
                    if remaining <= 0 { timer.invalidate(); self.countdownTimer = nil; self.launch() } else { self.phase = .countdown(remaining) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            countdownTimer = timer
        } else {
            launch()
        }
    }

    private func launch() {
        let run = ClickRun()
        self.run = run
        startedAt = Date()
        phase = .running
        limit = repeatMode == .count ? max(1, repeatCount) : nil
        deadline = repeatMode == .duration ? Date().addingTimeInterval(max(1, durationSeconds)) : nil
        if !isDryRun { notify?("오토클릭 시작", "\(intervalText) · \(button.title) \(clickType.title)") }
        installEscMonitors()
        startUITimer()
        let plan = Plan(intervalMs: intervalMs, jitter: jitterPercent / 100, button: button, double: clickType == .double,
                        fixed: positionMode == .fixed ? fixedPoint : nil, stopOnMove: stopOnMove && positionMode == .fixed,
                        limit: limit, deadline: deadline, dryRun: isDryRun, source: source)
        let queue = self.queue
        queue.async {
            Self.tick(plan: plan, run: run, queue: queue, first: true) { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.run === run else { return }
                    self.finishOnMain(reason: reason)
                }
            }
        }
    }

    func stop(reason: String? = nil) {
        guard isActive else { return }
        if case .countdown = phase {
            countdownTimer?.invalidate()
            countdownTimer = nil
            phase = .idle
            lastStopReason = reason ?? "취소"
            return
        }
        run?.cancel()
        finishOnMain(reason: reason ?? "정지")
    }

    private func finishOnMain(reason: String) {
        guard isRunning else { return }
        run?.cancel()
        syncCounter()
        phase = .idle
        lastStopReason = reason
        removeEscMonitors()
        uiTimer?.invalidate()
        uiTimer = nil
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        if !isDryRun { notify?("오토클릭 정지", "\(clickCount)회 · \(reason)") }
    }

    // MARK: Click loop (background queue)

    private struct Plan {
        let intervalMs: Double
        let jitter: Double
        let button: MouseButton
        let double: Bool
        let fixed: CGPoint?
        let stopOnMove: Bool
        let limit: Int?
        let deadline: Date?
        let dryRun: Bool
        let source: CGEventSource?
    }

    /// Runs entirely off the main actor; the shared state lives in `run`, which `stop()` cancels.
    nonisolated private static func tick(plan: Plan, run: ClickRun, queue: DispatchQueue, first: Bool, onEnd: @escaping @Sendable (String) -> Void) {
        guard !run.cancelled else { return }
        let done = run.count
        if let limit = plan.limit, done >= limit { run.cancel(); onEnd("\(limit)번 클릭 완료"); return }
        if let deadline = plan.deadline, Date() >= deadline { run.cancel(); onEnd("시간이 다 됐어요"); return }

        let pointer = pointerLocation()
        let target = plan.fixed ?? pointer
        if plan.stopOnMove, !first, let fixed = plan.fixed, hypot(pointer.x - fixed.x, pointer.y - fixed.y) > 24 {
            run.cancel()
            onEnd("마우스를 움직여서 안전하게 멈췄어요")
            return
        }
        if !plan.dryRun { post(click: plan, at: target) }
        run.increment()

        var interval = max(5, plan.intervalMs) / 1000
        if plan.jitter > 0 { interval *= 1 + Double.random(in: -plan.jitter...plan.jitter) }
        queue.asyncAfter(deadline: .now() + interval) { tick(plan: plan, run: run, queue: queue, first: false, onEnd: onEnd) }
    }

    nonisolated private static func pointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    nonisolated private static func post(click plan: Plan, at point: CGPoint) {
        func send(_ type: CGEventType, state: Int64) {
            guard let event = CGEvent(mouseEventSource: plan.source, mouseType: type, mouseCursorPosition: point, mouseButton: plan.button.cgButton) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: state)
            event.post(tap: .cghidEventTap)
        }
        send(plan.button.downType, state: 1)
        send(plan.button.upType, state: 1)
        if plan.double {
            usleep(20_000)
            send(plan.button.downType, state: 2)
            send(plan.button.upType, state: 2)
        }
    }

    // MARK: UI refresh / safety

    private func startUITimer() {
        uiTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.syncCounter()
                if let startedAt = self.startedAt { self.elapsed = Date().timeIntervalSince(startedAt) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    private func syncCounter() {
        let value = run?.count ?? 0
        if value != clickCount { clickCount = value }
    }

    /// Esc anywhere stops the run (global monitor works once Accessibility is granted).
    private func installEscMonitors() {
        removeEscMonitors()
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.stop(reason: "Esc로 정지") }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in handler(event); return event }) { escMonitors.append(local) }
    }

    private func removeEscMonitors() {
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
    }

    // MARK: Fixed point capture

    /// Three-second countdown, then remembers where the pointer is (so the user can move it to the target).
    func captureFixedPoint() {
        guard captureCountdown == nil else { return }
        captureCountdown = 3
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let remaining = self.captureCountdown else { timer.invalidate(); return }
                if remaining <= 1 {
                    timer.invalidate()
                    self.captureCountdown = nil
                    self.fixedPoint = Self.pointerLocation()
                    self.positionMode = .fixed
                    self.notify?("오토클릭 위치 저장", self.fixedPointText)
                } else {
                    self.captureCountdown = remaining - 1
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    var fixedPointText: String { "x \(Int(fixedPoint.x)) · y \(Int(fixedPoint.y))" }

    var intervalText: String {
        if intervalMs >= 60_000 { return String(format: "%.1f분", intervalMs / 60_000) }
        if intervalMs >= 1000 { return String(format: "%.2g초", intervalMs / 1000) }
        return "\(Int(intervalMs))ms"
    }

    static let presetsMs: [Double] = [10, 50, 100, 250, 500, 1000, 5000]

    func shutdown() {
        stop(reason: "앱 종료")
    }
}


/// Per-run shared state between the main actor and the click queue.
final class ClickRun: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _cancelled = false

    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func increment() { lock.lock(); _count += 1; lock.unlock() }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}
