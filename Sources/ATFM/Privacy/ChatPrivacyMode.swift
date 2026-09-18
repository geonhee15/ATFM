import AppKit
import Observation

/// One app (or browser + window-title keyword) that chat privacy applies to.
struct PrivacyTarget: Codable, Identifiable, Equatable {
    var id: String
    var bundleID: String            // exact bundle id, or a prefix when it ends with "*"
    var name: String
    var nameHint: String?           // running app's name must contain this (for "*" bundle ids)
    var titleKeyword: String?       // only windows whose title contains this (browser tabs)
    var urlKeywords: [String]?      // browsers: the front tab's URL must contain one of these (checked via AppleScript)
    var excludedTitles: [String]?   // windows with exactly these titles are never covered (e.g. KakaoTalk's main window)
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

    /// Browsers we can ask for the front tab's URL (Chromium family + Safari + Arc).
    var supportsURLCheck: Bool { ShortsBrowser(rawValue: bundleID) != nil }
    var needsWindowFilter: Bool { (titleKeyword?.isEmpty == false) || !(urlKeywords ?? []).isEmpty }

    /// Copies preset-defined behaviour onto a stored copy while keeping the user's own edits.
    func refreshed(from preset: PrivacyTarget) -> PrivacyTarget {
        var copy = preset
        copy.enabled = enabled
        copy.topInset = topInset
        copy.composerHeight = composerHeight
        copy.titleKeyword = titleKeyword
        return copy
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
        preset("kakao", "com.kakao.KakaoTalkMac", "카카오톡", composer: 130, excluded: ["카카오톡", "KakaoTalk"]),
        preset("gchat-app", "com.google.Chrome.app.*", "Google Chat (앱)", nameHint: "Google Chat", composer: 120),
        preset("gchat-chrome", "com.google.Chrome", "Google Chat (Chrome 탭)", top: 86, composer: 120, chatTab: true),
        preset("gchat-safari", "com.apple.Safari", "Google Chat (Safari 탭)", top: 52, composer: 120, chatTab: true),
        preset("gchat-arc", "company.thebrowser.Browser", "Google Chat (Arc 탭)", top: 36, composer: 120, chatTab: true),
        preset("gchat-firefox", "org.mozilla.firefox", "Google Chat (Firefox 탭)", top: 80, composer: 120, chatTab: true),
        preset("gchat-edge", "com.microsoft.edgemac", "Google Chat (Edge 탭)", top: 86, composer: 120, chatTab: true),
        preset("gchat-brave", "com.brave.Browser", "Google Chat (Brave 탭)", top: 86, composer: 120, chatTab: true),
        preset("slack", "com.tinyspeck.slackmacgap", "Slack", composer: 120),
        preset("discord", "com.hnc.Discord", "Discord", composer: 90),
        preset("telegram", "ru.keepcoder.Telegram", "Telegram", composer: 70),
        preset("whatsapp", "net.whatsapp.WhatsApp", "WhatsApp", composer: 80),
        preset("messages", "com.apple.MobileSMS", "메시지", composer: 64),
        preset("line", "jp.naver.line.mac", "LINE", composer: 120),
    ]

    /// Gmail-integrated Chat lives at mail.google.com/mail/u/<n>/#chat/…, standalone Chat at chat.google.com.
    /// A "*" in a keyword means every part must appear in the URL.
    static let googleChatURLs = ["chat.google.com", "google.com/chat", "google.com*#chat"]

    static func urlMatches(_ url: String, keywords: [String]) -> Bool {
        let lower = url.lowercased()
        return keywords.contains { keyword in
            keyword.lowercased().split(separator: "*").allSatisfy { part in lower.contains(part) }
        }
    }

    private static func preset(_ key: String, _ bundle: String, _ name: String, nameHint: String? = nil, top: Double = 0, composer: Double,
                               chatTab: Bool = false, excluded: [String]? = nil) -> PrivacyTarget {
        PrivacyTarget(id: "preset:\(key)", bundleID: bundle, name: name, nameHint: nameHint,
                      titleKeyword: chatTab ? "Google Chat" : nil, urlKeywords: chatTab ? googleChatURLs : nil, excludedTitles: excluded,
                      topInset: top, composerHeight: composer, enabled: true, isPreset: true)
    }
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
        for preset in PrivacyTarget.presets {
            if let index = loaded.firstIndex(where: { $0.id == preset.id }) {
                loaded[index] = loaded[index].refreshed(from: preset)
            } else {
                loaded.append(preset)
            }
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
        schedule(interval: Self.idleInterval)
        tick()
    }

    private static let idleInterval: TimeInterval = 0.15
    private static let followInterval: TimeInterval = 1.0 / 60.0   // smooth tracking while a window is covered
    @ObservationIgnored private var timerInterval: TimeInterval = 0

    private func schedule(interval: TimeInterval) {
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        timerInterval = 0
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
                                     urlKeywords: nil, excludedTitles: nil, topInset: 0, composerHeight: 110, enabled: true, isPreset: false))
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
              let target = targets.first(where: { $0.enabled && $0.matches(bundle: bundle, appName: app.localizedName) }) else {
            release()
            return
        }
        if let keywords = target.urlKeywords, !keywords.isEmpty, target.supportsURLCheck {
            pollFrontTabURL(of: target)
        }
        guard let window = frontWindow(of: app.processIdentifier, target: target) else {
            if activeName != nil || debugAllowSelf { debugLog?("no front window for \(target.name) (pid \(app.processIdentifier))") }
            release()
            return
        }
        schedule(interval: Self.followInterval)
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

    private func release() {
        if activeName != nil { activeName = nil }
        overlay.hide()
        currentWindowID = 0
        schedule(interval: Self.idleInterval)
    }

    /// The app's front window — only that one is ever covered. Returns nil when it is excluded
    /// (KakaoTalk's friend list) or, for browsers, when neither the title nor the front tab URL match.
    private func frontWindow(of pid: pid_t, target: PrivacyTarget) -> FrontWindow? {
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
            let title = (entry[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespaces)
            if let excluded = target.excludedTitles, let title, excluded.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
                debugLog?("front window #\(number) excluded by title")
                return nil
            }
            if target.needsWindowFilter {
                let titleOK = target.titleKeyword.map { keyword in !keyword.isEmpty && (title?.localizedCaseInsensitiveContains(keyword) ?? false) } ?? false
                guard titleOK || frontTabMatches(target) else {
                    debugLog?("front window #\(number) \(Int(bounds.width))x\(Int(bounds.height)) title(\(title?.count ?? -1) chars) fails filter")
                    return nil
                }
            }
            let frame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return FrontWindow(id: number, frame: frame, title: title)
        }
        return nil
    }

    // MARK: Browser front-tab URL (AppleScript, needs the Automation permission once)

    @ObservationIgnored private var tabURL = ""
    @ObservationIgnored private var tabURLBundle = ""
    @ObservationIgnored private var tabURLTime = Date.distantPast
    @ObservationIgnored private var tabProbeInFlight = false
    @ObservationIgnored private var tabProbeStarted = Date.distantPast

    private func frontTabMatches(_ target: PrivacyTarget) -> Bool {
        guard let keywords = target.urlKeywords, tabURLBundle == target.bundleID,
              Date().timeIntervalSince(tabURLTime) < 4 else { return false }
        return PrivacyTarget.urlMatches(tabURL, keywords: keywords)
    }

    private func pollFrontTabURL(of target: PrivacyTarget) {
        guard !tabProbeInFlight, Date().timeIntervalSince(tabProbeStarted) > 0.7 else { return }
        tabProbeInFlight = true
        tabProbeStarted = Date()
        let bundle = target.bundleID
        AppleScriptRunner.run(Self.frontTabScript(bundle: bundle), timeout: 3) { [weak self] output, error in
            guard let self else { return }
            self.tabProbeInFlight = false
            if let error {
                if error.contains("-1743") || error.contains("not allowed") || error.contains("허용") {
                    self.lastError = "브라우저 탭 주소를 읽으려면 시스템 설정 › 개인정보 보호 › 자동화에서 ATFM → \(target.name.components(separatedBy: " (").first ?? "브라우저") 허용"
                }
                self.tabURL = ""
                return
            }
            self.tabURL = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self.tabURLBundle = bundle
            self.tabURLTime = Date()
            if self.lastError?.contains("자동화") == true { self.lastError = nil }
        }
    }

    static func frontTabScript(bundle: String) -> String {
        if bundle == "com.apple.Safari" {
            return "tell application id \"\(bundle)\" to if (count of windows) > 0 then get URL of current tab of front window"
        }
        return "tell application id \"\(bundle)\" to if (count of windows) > 0 then get URL of active tab of front window"
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
