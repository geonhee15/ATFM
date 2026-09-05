import AVFoundation
import AppKit
import Observation

enum ClapAction: String, CaseIterable, Identifiable {
    case lock, screensaver, displayOff
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lock: return "화면 잠금"
        case .screensaver: return "화면 보호기"
        case .displayOff: return "디스플레이 끄기"
        }
    }
}

enum ClapSensitivity: String, CaseIterable, Identifiable {
    case low, normal, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: return "둔감"
        case .normal: return "보통"
        case .high: return "민감"
        }
    }
    /// (absolute minimum peak, peak over noise floor) — Security-Protocol-1 defaults are "보통".
    var thresholds: (minPeak: Double, overFloor: Double) {
        switch self {
        case .low: return (0.16, 16)
        case .normal: return (0.10, 12)
        case .high: return (0.06, 8)
        }
    }
}

/// 박수 잠금: listens for a double clap and locks the Mac (or runs another quick action).
@MainActor
@Observable
final class ClapLock {
    private(set) var isEnabled: Bool
    private(set) var action: ClapAction
    private(set) var sensitivity: ClapSensitivity
    private(set) var testMode: Bool
    private(set) var isListening = false
    private(set) var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var level: Double = 0          // latest block peak (0–1)
    private(set) var noiseFloor: Double = 0
    private(set) var awaitingSecond = false
    private(set) var lastDetectedAt: Date?
    private(set) var detectionCount = 0
    private(set) var lastError: String?
    private(set) var cooldownUntil: Date?
    private(set) var lastNotice: String?

    @ObservationIgnored private let detector = ClapDetector()
    @ObservationIgnored private var input: ClapAudioInput?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLevel = 0.0
    private static let cooldownSec = 5.0
    private static let startupGraceSec = 2.0

    private enum Key {
        static let enabled = "clapLockEnabled"
        static let action = "clapLockAction"
        static let sensitivity = "clapLockSensitivity"
        static let test = "clapLockTestMode"
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        action = ClapAction(rawValue: defaults.string(forKey: Key.action) ?? "") ?? .lock
        sensitivity = ClapSensitivity(rawValue: defaults.string(forKey: Key.sensitivity) ?? "") ?? .normal
        testMode = defaults.bool(forKey: Key.test)
        applySensitivity()
    }

    var isInCooldown: Bool { cooldownUntil.map { $0 > Date() } ?? false }

    var statusText: String {
        if !isEnabled { return "꺼짐" }
        if permission == .denied || permission == .restricted { return "마이크 권한 없음" }
        if !isListening { return "마이크 준비 중…" }
        if isInCooldown { return "잠시 대기 중" }
        if awaitingSecond { return "박수 1 · 한 번 더!" }
        return testMode ? "듣는 중 (테스트)" : "듣는 중"
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Key.enabled)
        if on { start() } else { stop() }
    }

    func setAction(_ value: ClapAction) {
        action = value
        UserDefaults.standard.set(value.rawValue, forKey: Key.action)
    }

    func setSensitivity(_ value: ClapSensitivity) {
        sensitivity = value
        UserDefaults.standard.set(value.rawValue, forKey: Key.sensitivity)
        applySensitivity()
    }

    func setTestMode(_ on: Bool) {
        testMode = on
        UserDefaults.standard.set(on, forKey: Key.test)
    }

    private func applySensitivity() {
        var config = detector.config
        config.absMinPeak = sensitivity.thresholds.minPeak
        config.peakOverFloor = sensitivity.thresholds.overFloor
        detector.config = config
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard isEnabled, !isListening else { return }
        lastError = nil
        permission = AVCaptureDevice.authorizationStatus(for: .audio)
        switch permission {
        case .authorized:
            beginListening()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permission = granted ? .authorized : .denied
                    if granted, self.isEnabled { self.beginListening() }
                }
            }
        default:
            lastError = "마이크 권한이 필요해요. 시스템 설정 → 개인정보 보호 → 마이크에서 ATFM을 켜 주세요."
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        input?.stop()
        input = nil
        isListening = false
        awaitingSecond = false
        level = 0
    }

    private func beginListening() {
        let audio = ClapAudioInput(detector: detector)
        audio.onLevel = { [weak self] peak in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.level = peak }
            }
        }
        do {
            detector.reset()
            try audio.start()
            input = audio
            isListening = true
            cooldownUntil = Date().addingTimeInterval(Self.startupGraceSec)
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } catch {
            lastError = "마이크를 열지 못했어요: \(error.localizedDescription)"
            isListening = false
        }
    }

    private func poll() {
        let now = CACurrentMediaTime()
        noiseFloor = detector.floor
        awaitingSecond = detector.awaitingSecondClap(now: now)
        guard let (_, second) = detector.pollDouble(now: now) else { return }
        _ = second
        guard !isInCooldown else { return }
        cooldownUntil = Date().addingTimeInterval(Self.cooldownSec)
        detectionCount += 1
        lastDetectedAt = Date()
        if testMode {
            lastNotice = "박수 감지! (테스트 모드라 잠그지 않았어요)"
            return
        }
        lastNotice = "박수 감지 → \(action.title)"
        perform(action)
    }

    private func perform(_ action: ClapAction) {
        switch action {
        case .lock:
            do { try ScreenControl.lockScreen() } catch { lastError = error.localizedDescription }
        case .screensaver:
            ScreenControl.startScreenSaver()
        case .displayOff:
            do { try ScreenControl.sleepDisplay() } catch { lastError = error.localizedDescription }
        }
    }
}
