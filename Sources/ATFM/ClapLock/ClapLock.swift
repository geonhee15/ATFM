import AVFoundation
import AppKit
import Observation

/// Something to do in addition to (or instead of) the Security-Protocol-1 lockdown.
enum ClapExtraAction: String, CaseIterable, Identifiable {
    case none, lock, screensaver, displayOff
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "없음"
        case .lock: return "화면 잠금"
        case .screensaver: return "화면 보호기"
        case .displayOff: return "디스플레이 끄기"
        }
    }
}

enum SP1LockStyle: String, CaseIterable, Identifiable {
    case jarvis, simple
    var id: String { rawValue }
    var title: String { self == .jarvis ? "JARVIS 원본" : "ATFM 심플" }
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
    /// Fire Security-Protocol-1's gesture lockdown (shade + UNLOCK + HUD auth).
    private(set) var useSP1: Bool
    private(set) var extra: ClapExtraAction
    private(set) var sp1Running = false
    private(set) var sensitivity: ClapSensitivity
    private(set) var testMode: Bool
    private(set) var useCamera: Bool
    private(set) var isListening = false
    private(set) var isWatching = false          // camera hand gate running
    private(set) var handCount = 0
    private(set) var secondsSinceHands: Double = .infinity
    private(set) var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var cameraPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var level: Double = 0          // latest block peak (0–1)
    private(set) var noiseFloor: Double = 0
    private(set) var awaitingSecond = false
    private(set) var lastDetectedAt: Date?
    private(set) var detectionCount = 0
    private(set) var lastError: String?
    private(set) var cooldownUntil: Date?
    private(set) var lastNotice: String?

    @ObservationIgnored private let detector = ClapDetector()
    @ObservationIgnored private let handGate = HandGate()
    @ObservationIgnored private var input: ClapAudioInput?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLevel = 0.0
    private static let cooldownSec = 5.0
    private static let startupGraceSec = 2.0

    private enum Key {
        static let enabled = "clapLockEnabled"
        static let useSP1 = "clapLockUseSP1"
        static let extra = "clapLockExtraAction"
        static let sensitivity = "clapLockSensitivity"
        static let test = "clapLockTestMode"
        static let camera = "clapLockUseCamera"
    }
    private static let handsRecentSec = 3.0

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        let installed = SP1Bridge.shared.isInstalled
        useSP1 = (defaults.object(forKey: Key.useSP1) as? Bool) ?? installed
        extra = ClapExtraAction(rawValue: defaults.string(forKey: Key.extra) ?? "") ?? (installed ? .none : .lock)
        sensitivity = ClapSensitivity(rawValue: defaults.string(forKey: Key.sensitivity) ?? "") ?? .normal
        testMode = defaults.bool(forKey: Key.test)
        useCamera = (defaults.object(forKey: Key.camera) as? Bool) ?? true
        sp1Running = SP1Bridge.shared.isRunning()
        applySensitivity()
        // A previous ATFM run may have died while it owned detection: hand the daemon back.
        if !isEnabled, SP1Bridge.shared.daemonSuspended { SP1Bridge.shared.resumeDaemon() }
        SP1Bridge.shared.onExternalExit = { [weak self] in
            guard let self else { return }
            self.lastNotice = "Security Protocol 1 잠금이 해제됐어요"
            self.refreshSP1Status()
            if self.isEnabled, self.useCamera { self.startCamera() }
        }
    }

    var sp1Owned: Bool { isEnabled && useSP1 && SP1Bridge.shared.daemonSuspended }
    var lockdownActive: Bool { SP1Bridge.shared.isExternalLockdownActive }

    var sp1Installed: Bool { SP1Bridge.shared.isInstalled }

    var sp1Style: SP1LockStyle {
        SP1LockStyle(rawValue: SP1Bridge.shared.lockStyle) ?? .simple
    }

    /// Lock-screen look used by SP1 on the next lockdown (written to its theme.json right away).
    func setSP1Style(_ style: SP1LockStyle) {
        SP1Bridge.shared.lockStyle = style.rawValue
        SP1Bridge.shared.writeTheme(ThemeManager.shared.current)
        sp1StyleVersion += 1
    }
    private(set) var sp1StyleVersion = 0

    /// Human-readable "what happens on a double clap".
    var actionSummary: String {
        var parts: [String] = []
        if useSP1 { parts.append("Security Protocol 1 잠금") }
        if extra != .none { parts.append(extra.title) }
        return parts.isEmpty ? "(동작 없음)" : parts.joined(separator: " + ")
    }

    func refreshSP1Status() {
        sp1Running = SP1Bridge.shared.isRunning()
    }

    func launchSP1() {
        SP1Bridge.shared.launch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { self.refreshSP1Status() }
        }
    }

    var isInCooldown: Bool { cooldownUntil.map { $0 > Date() } ?? false }

    var statusText: String {
        if !isEnabled { return "꺼짐" }
        if permission == .denied || permission == .restricted { return "마이크 권한 없음" }
        if !isListening { return "마이크 준비 중…" }
        if lockdownActive { return "SP1 잠금 진행 중" }
        if isInCooldown { return "잠시 대기 중" }
        if awaitingSecond { return "박수 1 · 한 번 더!" }
        let eyes = isWatching ? (handCount > 0 ? " · 손 \(handCount)" : " · 손 없음") : ""
        return (testMode ? "듣는 중 (테스트)" : "듣는 중") + eyes
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Key.enabled)
        if on {
            if useSP1 { SP1Bridge.shared.suspendDaemon() }
            start()
        } else {
            stop()
            if SP1Bridge.shared.daemonSuspended { SP1Bridge.shared.resumeDaemon() }
        }
        refreshSP1Status()
    }

    func setUseSP1(_ on: Bool) {
        useSP1 = on
        UserDefaults.standard.set(on, forKey: Key.useSP1)
        if isEnabled {
            if on { SP1Bridge.shared.suspendDaemon() } else if SP1Bridge.shared.daemonSuspended { SP1Bridge.shared.resumeDaemon() }
        }
        refreshSP1Status()
    }

    func setUseCamera(_ on: Bool) {
        useCamera = on
        UserDefaults.standard.set(on, forKey: Key.camera)
        if isEnabled {
            if on { startCamera() } else { stopCamera() }
        }
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func setExtra(_ value: ClapExtraAction) {
        extra = value
        UserDefaults.standard.set(value.rawValue, forKey: Key.extra)
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
        // Owning detection means the background SP1 daemon must be down (launch path + toggle path).
        if useSP1, !SP1Bridge.shared.daemonSuspended { SP1Bridge.shared.suspendDaemon() }
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
        stopCamera()
    }

    /// Called on app quit: give the daemon back if we took it.
    func shutdown() {
        stop()
        if SP1Bridge.shared.daemonSuspended { SP1Bridge.shared.resumeDaemon() }
    }

    // MARK: Camera hand gate

    private func startCamera() {
        guard useCamera, !isWatching else { return }
        cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraPermission {
        case .authorized:
            beginWatching()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.cameraPermission = granted ? .authorized : .denied
                    if granted, self.isEnabled, self.useCamera { self.beginWatching() }
                }
            }
        default:
            lastError = "카메라 권한이 없어 손 확인 없이(마이크만) 동작해요. 시스템 설정 → 카메라에서 ATFM을 켜 주세요."
        }
    }

    private func beginWatching() {
        handGate.onFrame = { [weak self] count in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handCount = count }
            }
        }
        handGate.onVisionDoubleClap = { [weak self] time in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.visionDoubleClap(at: time) }
            }
        }
        do {
            try handGate.start()
            isWatching = true
        } catch {
            lastError = "카메라를 열지 못했어요: \(error.localizedDescription)"
        }
    }

    private func stopCamera() {
        handGate.stop()
        isWatching = false
        handCount = 0
    }

    private func beginListening() {
        startCamera()
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

    @ObservationIgnored private var pollCount = 0

    private func poll() {
        let now = CACurrentMediaTime()
        noiseFloor = detector.floor
        pollCount += 1
        if pollCount % 20 == 0 { refreshSP1Status() }   // every 2 s
        awaitingSecond = detector.awaitingSecondClap(now: now)
        if isWatching { secondsSinceHands = handGate.detector.secondsSinceHands(now: now) }

        // Fusion, same order as SP1: audio double clap gated by the camera; vision clap needs a sound.
        var fired: String?
        if let (first, second) = detector.pollDouble(now: now) {
            if isWatching, handGate.detector.secondsSinceHands(now: now) >= Self.handsRecentSec {
                lastNotice = "박수 소리는 들었지만 최근에 손이 안 보여서 무시했어요 (외부 소음?)"
            } else if isWatching, handGate.detector.typingPosture(from: first - 0.4, to: second + 0.25) {
                lastNotice = "박수 소리 동안 두 손이 떨어져 있어서 무시했어요 (키보드 타건 추정)"
            } else {
                fired = isWatching ? "오디오 + 손 확인" : "오디오"
            }
        }
        guard fired != nil else { return }
        guard !isInCooldown else { return }
        cooldownUntil = Date().addingTimeInterval(Self.cooldownSec)
        detectionCount += 1
        lastDetectedAt = Date()
        if testMode {
            lastNotice = "박수 감지! (테스트 모드라 잠그지 않았어요)"
            return
        }
        lastNotice = "박수 감지 → \(actionSummary)"
        performActions()
    }

    /// SP1's secondary path: the camera saw two hands meet twice — only counts if a sound came with it.
    private func visionDoubleClap(at time: Double) {
        guard isEnabled, isListening, !isInCooldown else { return }
        guard detector.onsetNear(time, tolerance: 0.6) else {
            lastNotice = "손이 모이는 건 봤지만 소리가 없어서 무시했어요"
            return
        }
        cooldownUntil = Date().addingTimeInterval(Self.cooldownSec)
        detectionCount += 1
        lastDetectedAt = Date()
        if testMode {
            lastNotice = "박수 감지 (손 + 소리)! (테스트 모드라 잠그지 않았어요)"
            return
        }
        lastNotice = "박수 감지 (손 + 소리) → \(actionSummary)"
        performActions()
    }

    private func performActions() {
        if useSP1 {
            do {
                stopCamera()   // hand the camera to SP1's lockdown process; resumes when it exits
                try SP1Bridge.shared.triggerLockdown()
            } catch {
                lastError = error.localizedDescription
                if useCamera { startCamera() }
            }
        }
        guard extra != .none else { return }
        // Let SP1's shade appear first so the native lock screen sits on top of it.
        let delay: TimeInterval = useSP1 ? 0.8 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { self.perform(self.extra) }
        }
    }

    private func perform(_ action: ClapExtraAction) {
        switch action {
        case .none:
            break
        case .lock:
            do { try ScreenControl.lockScreen() } catch { lastError = error.localizedDescription }
        case .screensaver:
            ScreenControl.startScreenSaver()
        case .displayOff:
            do { try ScreenControl.sleepDisplay() } catch { lastError = error.localizedDescription }
        }
    }
}
