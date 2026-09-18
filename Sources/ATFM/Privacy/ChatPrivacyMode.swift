import AppKit
import Observation

/// One app (or browser + window-title keyword) that chat privacy applies to.
struct PrivacyTarget: Codable, Identifiable, Equatable {
    var id: String
    var bundleID: String            // exact bundle id, or a prefix when it ends with "*"
    var name: String
    var nameHint: String?           // running app's name must contain this (for "*" bundle ids)
    var titleKeyword: String?       // only windows whose title contains this (browser tabs)
    var topInset: Double            // points at the top of the window left uncovered (toolbar)
    var composerHeight: Double      // bottom strip treated as the message composer
    var enabled: Bool
    var isPreset: Bool

    func matches(bundle: String, appName: String?) -> Bool {
        if bundleID.hasSuffix("*") {
            guard bundle.lowercased().hasPrefix(bundleID.dropLast().lowercased()) else { return false }
        } else if bundle.caseInsensitiveCompare(bundleID) != .orderedSame {
            return false
        }
        if let hint = nameHint, !hint.isEmpty {
            return appName?.localizedCaseInsensitiveContains(hint) ?? false
        }
        return true
    }

    var isInstalled: Bool {
        if bundleID.hasSuffix("*") {
            return NSWorkspace.shared.runningApplications.contains { app in
                guard let id = app.bundleIdentifier else { return false }
                return matches(bundle: id, appName: app.localizedName)
            } || Self.chromeApps().contains { $0.localizedCaseInsensitiveContains(nameHint ?? "\u{0}") }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Names of Chrome-installed web apps (PWAs) so the Google Chat preset shows when installed.
    private static func chromeApps() -> [String] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return items.map { ($0 as NSString).deletingPathExtension }
    }

    var appIconPath: String? {
        if bundleID.hasSuffix("*") {
            return NSWorkspace.shared.runningApplications.first { app in
                guard let id = app.bundleIdentifier else { return false }
                return matches(bundle: id, appName: app.localizedName)
            }?.bundleURL?.path
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }

    static let presets: [PrivacyTarget] = [
        PrivacyTarget(id: "preset:kakao", bundleID: "com.kakao.KakaoTalkMac", name: "카카오톡", nameHint: nil, titleKeyword: nil, topInset: 0, composerHeight: 130, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:gchat-app", bundleID: "com.google.Chrome.app.*", name: "Google Chat (앱)", nameHint: "Google Chat", titleKeyword: nil, topInset: 0, composerHeight: 120, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:gchat-chrome", bundleID: "com.google.Chrome", name: "Google Chat (Chrome 탭)", nameHint: nil, titleKeyword: "Google Chat", topInset: 86, composerHeight: 120, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:gchat-safari", bundleID: "com.apple.Safari", name: "Google Chat (Safari 탭)", nameHint: nil, titleKeyword: "Google Chat", topInset: 52, composerHeight: 120, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:gchat-arc", bundleID: "company.thebrowser.Browser", name: "Google Chat (Arc 탭)", nameHint: nil, titleKeyword: "Google Chat", topInset: 36, composerHeight: 120, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:gchat-firefox", bundleID: "org.mozilla.firefox", name: "Google Chat (Firefox 탭)", nameHint: nil, titleKeyword: "Google Chat", topInset: 80, composerHeight: 120, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:gchat-edge", bundleID: "com.microsoft.edgemac", name: "Google Chat (Edge 탭)", nameHint: nil, titleKeyword: "Google Chat", topInset: 86, composerHeight: 120, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:slack", bundleID: "com.tinyspeck.slackmacgap", name: "Slack", nameHint: nil, titleKeyword: nil, topInset: 0, composerHeight: 120, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:discord", bundleID: "com.hnc.Discord", name: "Discord", nameHint: nil, titleKeyword: nil, topInset: 0, composerHeight: 90, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:telegram", bundleID: "ru.keepcoder.Telegram", name: "Telegram", nameHint: nil, titleKeyword: nil, topInset: 0, composerHeight: 70, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:whatsapp", bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", nameHint: nil, titleKeyword: nil, topInset: 0, composerHeight: 80, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:messages", bundleID: "com.apple.MobileSMS", name: "메시지", nameHint: nil, titleKeyword: nil, topInset: 0, composerHeight: 64, enabled: true, isPreset: true),
        PrivacyTarget(id: "preset:line", bundleID: "jp.naver.line.mac", name: "LINE", nameHint: nil, titleKeyword: nil, topInset: 0, composerHeight: 120, enabled: true, isPreset: true),
    ]
}

/// 채팅 프라이버시: while a chosen messenger is the front app, a glass sheet covers its chat history
/// except the newest N messages and the composer. Toggled from the panel or a global hotkey.
@MainActor
@Observable
final class ChatPrivacyMode {
    private(set) var isEnabled: Bool
    private(set) var targets: [PrivacyTarget]
    var recentCount: Int {
        didSet { UserDefaults.standard.set(recentCount, forKey: Self.recentKey); lastAnalysis = .distantPast }
    }
    var tone: PrivacyOverlay.Tone {
        didSet { UserDefaults.standard.set(tone.rawValue, forKey: Self.toneKey); overlay.tone = tone }
    }
    /// Name of the app currently being covered (nil when nothing is).
    private(set) var activeName: String?
    private(set) var visibleMessages = 0
    private(set) var lastError: String?

    @ObservationIgnored var onToggled: ((Bool) -> Void)?
    @ObservationIgnored private let overlay = PrivacyOverlay()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var currentWindowID: CGWindowID = 0
    @ObservationIgnored private var currentClear: CGFloat = 0
    @ObservationIgnored private var lastAnalysis = Date.distantPast
    @ObservationIgnored private var analysisInFlight = false
    @ObservationIgnored var debugAllowSelf = false
    @ObservationIgnored var debugLog: ((String) -> Void)?

    private static let enabledKey = "chatPrivacyEnabled"
    private static let targetsKey = "chatPrivacyTargets"
    private static let recentKey = "chatPrivacyRecent"
    private static let toneKey = "chatPrivacyTone"

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let stored = defaults.integer(forKey: Self.recentKey)
        recentCount = (1...5).contains(stored) ? stored : 2
        tone = PrivacyOverlay.Tone(rawValue: defaults.string(forKey: Self.toneKey) ?? "") ?? .auto
        var loaded: [PrivacyTarget] = []
        if let data = defaults.data(forKey: Self.targetsKey), let decoded = try? JSONDecoder().decode([PrivacyTarget].self, from: data) {
            loaded = decoded
        }
        for preset in PrivacyTarget.presets where !loaded.contains(where: { $0.id == preset.id }) {
            loaded.append(preset)
        }
        targets = loaded
        overlay.tone = tone
    }

    // MARK: Enable / disable

    func setEnabled(_ on: Bool, announce: Bool = true) {
        guard on != isEnabled else { return }
        isEnabled = on
        if !debugAllowSelf { UserDefaults.standard.set(on, forKey: Self.enabledKey) }
        if on { start() } else { stop() }
        if announce { onToggled?(on) }
    }

    func toggle() { setEnabled(!isEnabled) }

    func start() {
        guard isEnabled, timer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        overlay.hide()
        currentWindowID = 0
        activeName = nil
    }

    // MARK: Targets

    /// Presets that are installed plus everything the user added.
    var visibleTargets: [PrivacyTarget] {
        targets.filter { !$0.isPreset || $0.isInstalled }
    }

    func setTarget(_ id: String, enabled: Bool) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[index].enabled = enabled
        saveTargets()
    }

    func update(_ target: PrivacyTarget) {
        guard let index = targets.firstIndex(where: { $0.id == target.id }) else { return }
        targets[index] = target
        saveTargets()
        lastAnalysis = .distantPast
    }

    func remove(_ id: String) {
        targets.removeAll { $0.id == id && !$0.isPreset }
        saveTargets()
    }

    func add(app: NSRunningApplication) {
        guard let bundle = app.bundleIdentifier else { return }
        let id = "custom:\(bundle)"
        guard !targets.contains(where: { $0.id == id }) else { return }
        targets.append(PrivacyTarget(id: id, bundleID: bundle, name: app.localizedName ?? bundle, nameHint: nil, titleKeyword: nil,
                                     topInset: 0, composerHeight: 110, enabled: true, isPreset: false))
        saveTargets()
    }

    /// Development only: register the sample-window target without persisting it.
    func addDebugTarget(_ target: PrivacyTarget) {
        targets.removeAll { $0.id == target.id }
        targets.insert(target, at: 0)
    }

    /// Running apps with a UI that aren't in the list yet (for the "add" menu).
    var addableApps: [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.bundleIdentifier != nil }
            .filter { app in !targets.contains { $0.matches(bundle: app.bundleIdentifier ?? "", appName: app.localizedName) } }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func saveTargets() {
        if let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: Self.targetsKey)
        }
    }

    // MARK: Tracking the front window

    private struct FrontWindow {
        var id: CGWindowID
        var frame: NSRect      // AppKit coordinates
        var title: String?
    }

    private func tick() {
        guard isEnabled else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              debugAllowSelf || app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let target = targets.first(where: { $0.enabled && $0.matches(bundle: bundle, appName: app.localizedName) }),
              let window = frontWindow(of: app.processIdentifier, titleKeyword: target.titleKeyword) else {
            if activeName != nil { activeName = nil }
            overlay.hide()
            currentWindowID = 0
            return
        }
        if window.id != currentWindowID {
            currentWindowID = window.id
            currentClear = Double(target.composerHeight) + 150
            lastAnalysis = .distantPast
        }
        if activeName != target.name { activeName = target.name }
        overlay.show(windowFrame: window.frame, topInset: CGFloat(target.topInset), clearHeight: currentClear, animated: true)
        if Date().timeIntervalSince(lastAnalysis) > 0.5 {
            analyze(window: window, target: target)
        }
    }

    private func frontWindow(of pid: pid_t, titleKeyword: String?) -> FrontWindow? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let overlayNumber = CGWindowID(max(0, overlay.windowNumber))
        for entry in info {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  (entry[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID, number != overlayNumber,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 240, bounds.height >= 160 else { continue }
            let title = entry[kCGWindowName as String] as? String
            if let keyword = titleKeyword, !keyword.isEmpty {
                guard let title, title.localizedCaseInsensitiveContains(keyword) else { continue }
            }
            let frame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return FrontWindow(id: number, frame: frame, title: title)
        }
        return nil
    }

    private func analyze(window: FrontWindow, target: PrivacyTarget) {
        guard !analysisInFlight else { return }
        analysisInFlight = true
        lastAnalysis = Date()
        let windowID = window.id
        let height = window.frame.height
        let composer = CGFloat(target.composerHeight)
        let count = recentCount
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .nominalResolution])
            let result = image.flatMap { ChatLayoutAnalyzer.analyze($0, windowHeight: height, composerHeight: composer, recentCount: count) }
            await MainActor.run {
                guard let self else { return }
                self.analysisInFlight = false
                guard self.currentWindowID == windowID else { return }
                if let result {
                    self.currentClear = result.clearHeight
                    self.visibleMessages = min(result.messageCount, count)
                    self.lastError = nil
                    self.debugLog?("blocks=\(result.blocks.count) clear=\(Int(result.clearHeight)) visible=\(self.visibleMessages)")
                } else {
                    self.lastError = "창 이미지를 읽지 못했어요 (화면 기록 권한 확인)"
                }
            }
        }
    }
}
