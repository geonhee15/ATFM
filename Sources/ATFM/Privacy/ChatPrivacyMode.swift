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
        preset("kakao", "com.kakao.KakaoTalkMac", "카카오톡", top: 88, composer: 130, excluded: ["카카오톡", "KakaoTalk"]),
        preset("gchat-app", "com.google.Chrome.app.*", "Google Chat (앱)", nameHint: "Google Chat", top: 64, composer: 120),
        preset("gchat-chrome", "com.google.Chrome", "Google Chat (Chrome 탭)", top: 64, composer: 120, chatTab: true),
        preset("gchat-safari", "com.apple.Safari", "Google Chat (Safari 탭)", top: 64, composer: 120, chatTab: true),
        preset("gchat-arc", "company.thebrowser.Browser", "Google Chat (Arc 탭)", top: 64, composer: 120, chatTab: true),
        preset("gchat-firefox", "org.mozilla.firefox", "Google Chat (Firefox 탭)", top: 150, composer: 120, chatTab: true),
        preset("gchat-edge", "com.microsoft.edgemac", "Google Chat (Edge 탭)", top: 64, composer: 120, chatTab: true),
        preset("gchat-brave", "com.brave.Browser", "Google Chat (Brave 탭)", top: 64, composer: 120, chatTab: true),
        preset("slack", "com.tinyspeck.slackmacgap", "Slack", top: 56, composer: 120),
        preset("discord", "com.hnc.Discord", "Discord", top: 48, composer: 90),
        preset("telegram", "ru.keepcoder.Telegram", "Telegram", top: 52, composer: 70),
        preset("whatsapp", "net.whatsapp.WhatsApp", "WhatsApp", top: 60, composer: 80),
        preset("messages", "com.apple.MobileSMS", "메시지", top: 52, composer: 64),
        preset("line", "jp.naver.line.mac", "LINE", top: 60, composer: 120),
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
    /// Height of the soft bottom edge in points (larger = no visible boundary, but the next-older message shows a little).
    var featherSize: Double {
        didSet { UserDefaults.standard.set(featherSize, forKey: Self.featherKey) }
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
    @ObservationIgnored private var currentCoverTop: CGFloat = 0        // points from the window bottom
    @ObservationIgnored private var currentCoverX: ClosedRange<CGFloat> = 0...0
    private(set) var headerDetected = false
    @ObservationIgnored private var lastAnalysis = Date.distantPast
    @ObservationIgnored private var analysisInFlight = false
    @ObservationIgnored var debugAllowSelf = false
    @ObservationIgnored var debugLog: ((String) -> Void)?
    var debugOverlayDescription: String { overlay.debugMaskDescription + " clear=\(Int(currentClear)) coverTop=\(Int(currentCoverTop)) feather=\(Int(featherSize))" }

    private static let enabledKey = "chatPrivacyEnabled"
    private static let targetsKey = "chatPrivacyTargets"
    private static let recentKey = "chatPrivacyRecent"
    private static let toneKey = "chatPrivacyTone"
    private static let featherKey = "chatPrivacyFeather"

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let stored = defaults.integer(forKey: Self.recentKey)
        recentCount = (1...5).contains(stored) ? stored : 2
        tone = PrivacyOverlay.Tone(rawValue: defaults.string(forKey: Self.toneKey) ?? "") ?? .auto
        let storedFeather = defaults.double(forKey: Self.featherKey)
        featherSize = storedFeather > 0 ? min(120, max(8, storedFeather)) : 48
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
        let me = ProcessInfo.processInfo.processIdentifier
        let front = debugAllowSelf ? NSRunningApplication.current : NSWorkspace.shared.frontmostApplication
        guard let app = front, let bundle = app.bundleIdentifier,
              debugAllowSelf || app.processIdentifier != me,
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
            let panel = pagePanel(for: target, windowFrame: window.frame)
            currentCoverTop = panel.maxY - CGFloat(target.topInset)
            currentCoverX = panel.minX...panel.maxX
            lastAnalysis = .distantPast
        }
        if activeName != target.name { activeName = target.name }
        let cover = NSRect(x: currentCoverX.lowerBound, y: currentClear, width: currentCoverX.upperBound - currentCoverX.lowerBound,
                           height: max(0, currentCoverTop - currentClear))
        overlay.show(windowFrame: window.frame, cover: cover, feather: CGFloat(featherSize), animated: true)
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
        let maxLayer = debugAllowSelf ? 3 : 0          // the floating sample window sits on layer 3
        for entry in info {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  (entry[kCGWindowLayer as String] as? Int ?? 0) <= maxLayer,
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

    /// Geometry reported by the page (CSS px = points): toolbar height and the chat panel rect in viewport coordinates.
    struct PageGeometry: Equatable {
        var toolbar: CGFloat
        var innerWidth: CGFloat
        var innerHeight: CGFloat
        var panel: CGRect?      // viewport coords, origin top-left
    }
    @ObservationIgnored private var pageGeometry: PageGeometry?
    @ObservationIgnored private var pageJSUnavailableUntil = Date.distantPast
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

    /// The chat panel inside the browser window, in window coordinates (origin bottom-left).
    /// Falls back to the whole window below a default toolbar height when the page hasn't reported yet.
    private func pagePanel(for target: PrivacyTarget, windowFrame: NSRect) -> CGRect {
        let h = windowFrame.height, w = windowFrame.width
        guard let geometry = pageGeometry else {
            return CGRect(x: 0, y: 0, width: w, height: max(0, h - 86))
        }
        let toolbar = geometry.toolbar
        if let p = geometry.panel, p.width > 200, p.height > 150 {
            let top = toolbar + p.minY
            return CGRect(x: p.minX, y: max(0, h - top - p.height), width: min(p.width, w - p.minX), height: min(p.height, h - top))
        }
        return CGRect(x: 0, y: 0, width: w, height: max(0, h - toolbar))
    }

    private func pollFrontTabURL(of target: PrivacyTarget) {
        guard !tabProbeInFlight, Date().timeIntervalSince(tabProbeStarted) > 0.7 else { return }
        tabProbeInFlight = true
        tabProbeStarted = Date()
        let bundle = target.bundleID
        let withJS = Date() > pageJSUnavailableUntil
        AppleScriptRunner.run(Self.frontTabScript(bundle: bundle, geometry: withJS), timeout: 3) { [weak self] output, error in
            guard let self else { return }
            self.tabProbeInFlight = false
            if let error {
                let lower = error.lowercased()
                if lower.contains("javascript") || lower.contains("apple events") || lower.contains("turned off") {
                    self.pageJSUnavailableUntil = Date().addingTimeInterval(60)     // URL-only until JS is allowed again
                    self.pageGeometry = nil
                    return
                }
                if error.contains("-1743") || lower.contains("not allowed") || error.contains("허용") {
                    self.lastError = "브라우저 탭 주소를 읽으려면 시스템 설정 › 개인정보 보호 › 자동화에서 ATFM → \(target.name.components(separatedBy: " (").first ?? "브라우저") 허용"
                }
                self.tabURL = ""
                return
            }
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            self.tabURL = lines.first ?? ""
            self.tabURLBundle = bundle
            self.tabURLTime = Date()
            if lines.count > 1 { self.pageGeometry = Self.parseGeometry(lines[1]) }
            if self.lastError?.contains("자동화") == true { self.lastError = nil }
        }
    }

    static func parseGeometry(_ json: String) -> PageGeometry? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolbar = object["tb"] as? Double, let iw = object["iw"] as? Double, let ih = object["ih"] as? Double else { return nil }
        var panel: CGRect?
        if let p = object["panel"] as? [Double], p.count == 4 { panel = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
        return PageGeometry(toolbar: max(0, toolbar), innerWidth: iw, innerHeight: ih, panel: panel)
    }

    /// Chat panel geometry from the page: the Chat iframe (Gmail embeds Chat) or the main landmark.
    static let pageGeometryJS = """
    (() => { const r = e => { const b = e.getBoundingClientRect(); return [Math.round(b.left), Math.round(b.top), Math.round(b.width), Math.round(b.height)]; };
      let panel = null;
      const frames = Array.from(document.querySelectorAll('iframe')).filter(f => /chat/i.test(f.src || '') && f.getBoundingClientRect().width > 300)
        .sort((a, b) => { const A = a.getBoundingClientRect(), B = b.getBoundingClientRect(); return B.width * B.height - A.width * A.height; });
      if (frames.length) panel = r(frames[0]); else { const m = document.querySelector('[role=main]'); if (m) panel = r(m); }
      return JSON.stringify({ tb: outerHeight - innerHeight, iw: innerWidth, ih: innerHeight, panel }); })()
    """

    static func frontTabScript(bundle: String, geometry: Bool = false) -> String {
        let safari = bundle == "com.apple.Safari"
        let tab = safari ? "current tab of front window" : "active tab of front window"
        guard geometry else {
            return "tell application id \"\(bundle)\" to if (count of windows) > 0 then get URL of \(tab)"
        }
        let escaped = pageGeometryJS.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let exec = safari ? "do JavaScript \"\(escaped)\" in \(tab)" : "execute \(tab) javascript \"\(escaped)\""
        return """
        tell application id "\(bundle)"
            if (count of windows) is 0 then return ""
            set u to URL of \(tab)
            set g to \(exec)
            return u & linefeed & g
        end tell
        """
    }

    private func analyze(window: FrontWindow, target: PrivacyTarget) {
        guard !analysisInFlight else { return }
        analysisInFlight = true
        lastAnalysis = Date()
        let windowID = window.id
        let size = window.frame.size
        let composer = CGFloat(target.composerHeight)
        let header = CGFloat(target.topInset)
        let count = recentCount
        let panel: CGRect? = target.supportsURLCheck ? pagePanel(for: target, windowFrame: window.frame) : nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .nominalResolution])
            let result = image.flatMap { ChatLayoutAnalyzer.analyze($0, windowSize: size, panel: panel, headerInset: header,
                                                                    composerHeight: composer, recentCount: count) }
            await MainActor.run {
                guard let self else { return }
                self.analysisInFlight = false
                guard self.currentWindowID == windowID else { return }
                if let result {
                    self.currentClear = result.clearHeight
                    self.currentCoverTop = result.cover.maxY
                    self.currentCoverX = result.cover.minX...result.cover.maxX
                    self.headerDetected = result.detectedHeader
                    self.visibleMessages = min(result.messageCount, count)
                    self.lastError = nil
                    self.debugLog?("blocks=\(result.blocks.count) clear=\(Int(result.clearHeight)) coverTop=\(Int(result.cover.maxY)) header=\(result.detectedHeader) notice=\(Int(result.noticeHeight)) x=\(Int(result.cover.minX))-\(Int(result.cover.maxX)) visible=\(self.visibleMessages) first=\(result.blocks.prefix(4).map { "\(Int($0.bottom))-\(Int($0.top))" }) took=\(Int(ChatLayoutAnalyzer.lastDuration * 1000))ms")
                } else {
                    self.lastError = "창 이미지를 읽지 못했어요 (화면 기록 권한 확인)"
                }
            }
        }
    }
}
