import AppKit
import Observation

/// Browsers that can run JavaScript in a tab through Apple Events (Firefox can't).
enum ShortsBrowser: String, CaseIterable, Identifiable {
    case chrome = "com.google.Chrome"
    case chromeCanary = "com.google.Chrome.canary"
    case brave = "com.brave.Browser"
    case edge = "com.microsoft.edgemac"
    case vivaldi = "com.vivaldi.Vivaldi"
    case arc = "company.thebrowser.Browser"
    case safari = "com.apple.Safari"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .chrome: return "Chrome"
        case .chromeCanary: return "Chrome Canary"
        case .brave: return "Brave"
        case .edge: return "Edge"
        case .vivaldi: return "Vivaldi"
        case .arc: return "Arc"
        case .safari: return "Safari"
        }
    }

    var isSafari: Bool { self == .safari }

    /// How to switch on JavaScript-from-Apple-Events in this browser.
    var setupHint: String {
        isSafari
            ? "Safari 설정 › 고급 › '웹 개발자용 기능 보기'를 켠 뒤, 메뉴 막대 개발자 › 'Apple 이벤트의 JavaScript 허용'을 켜 주세요."
            : "\(name) 메뉴 막대 보기(View) › 개발자(Developer) › 'Apple 이벤트에서 JavaScript 허용'을 켜 주세요."
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty
    }

    /// AppleScript that runs `js` in every Shorts tab and returns one line per tab.
    func script(js: String) -> String {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let exec = isSafari ? "do JavaScript \"\(escaped)\" in t" : "execute t javascript \"\(escaped)\""
        return """
        tell application id "\(rawValue)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    if (URL of t) contains "youtube.com/shorts" then
                        try
                            set r to \(exec)
                            set out to out & r & linefeed
                        on error errMsg number errNum
                            set out to out & "ERR " & errNum & " " & errMsg & linefeed
                        end try
                    end if
                end repeat
            end repeat
            return out
        end tell
        """
    }
}

struct ShortsTabStatus: Identifiable, Equatable {
    let id: String            // browser + index
    let browser: ShortsBrowser
    var title: String
    var shortsID: String
    var plays: Int
    var time: Double
    var duration: Double
    var advanced: Int
    var method: String
}

/// Auto-advances YouTube Shorts in the user's browser: polls every Shorts tab through Apple Events,
/// keeps the in-page agent alive and shows what it is doing.
@MainActor
@Observable
final class AutoScroller {
    private(set) var isEnabled: Bool
    private(set) var repeatCount: Int
    private(set) var tabs: [ShortsTabStatus] = []
    private(set) var runningBrowsers: [ShortsBrowser] = []
    private(set) var problem: String?
    private(set) var setupHint: String?
    private(set) var advancedThisSession = 0
    private(set) var lastPollAt: Date?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var advancedByTab: [String: Int] = [:]

    private static let enabledKey = "autoScrollEnabled"
    private static let repeatKey = "autoScrollRepeat"
    static let repeatRange = 1...10

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let stored = UserDefaults.standard.integer(forKey: Self.repeatKey)
        repeatCount = Self.repeatRange.contains(stored) ? stored : 1
        refreshBrowsers()
    }

    func start() {
        if isEnabled { startPolling() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isEnabled { poll(enabled: false, synchronous: true) }   // tell the page agents to stop now
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            problem = nil
            startPolling()
        } else {
            timer?.invalidate()
            timer = nil
            poll(enabled: false, synchronous: false)
            tabs = []
        }
    }

    func setRepeatCount(_ count: Int) {
        let clamped = min(max(count, Self.repeatRange.lowerBound), Self.repeatRange.upperBound)
        guard clamped != repeatCount else { return }
        repeatCount = clamped
        UserDefaults.standard.set(clamped, forKey: Self.repeatKey)
        if isEnabled { poll(enabled: true, synchronous: false) }
    }

    func refreshBrowsers() {
        runningBrowsers = ShortsBrowser.allCases.filter(\.isRunning)
    }

    // MARK: Polling

    private func startPolling() {
        timer?.invalidate()
        poll(enabled: true, synchronous: false)
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(enabled: true, synchronous: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll(enabled: Bool, synchronous: Bool) {
        refreshBrowsers()
        guard inFlight == 0 || synchronous else { return }
        let js = ShortsAgent.call(repeat: repeatCount, enabled: enabled)
        if runningBrowsers.isEmpty {
            tabs = []
            problem = enabled ? "지원하는 브라우저가 실행 중이 아니에요 (Chrome · Brave · Edge · Vivaldi · Arc · Safari)" : nil
            setupHint = nil
            return
        }
        for browser in runningBrowsers {
            inFlight += 1
            Self.runOSAScript(browser.script(js: js), synchronous: synchronous) { [weak self] output, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                    guard enabled else { return }
                    self.handle(browser: browser, output: output, error: error)
                }
            }
        }
    }

    private func handle(browser: ShortsBrowser, output: String, error: String?) {
        lastPollAt = Date()
        if let error, !error.isEmpty {
            if error.contains("-1743") || error.lowercased().contains("not authorized") {
                problem = "\(browser.name)을(를) 제어할 권한이 없어요. 시스템 설정 › 개인정보 보호 및 보안 › 자동화에서 ATFM → \(browser.name)을 켜 주세요."
            } else {
                problem = "\(browser.name): \(error.prefix(160))"
            }
            setupHint = nil
            tabs.removeAll { $0.browser == browser }
            return
        }
        var found: [ShortsTabStatus] = []
        var hint: String?
        var firstError: String?
        for (index, rawLine) in output.split(separator: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("ERR") {
                let lower = line.lowercased()
                if lower.contains("javascript") && (lower.contains("turned off") || lower.contains("apple events") || lower.contains("not allowed")) {
                    hint = browser.setupHint
                } else if firstError == nil {
                    firstError = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let key = "\(browser.rawValue)#\(index)"
            let advanced = json["advanced"] as? Int ?? 0
            let previous = advancedByTab[key] ?? advanced
            if advanced > previous { advancedThisSession += advanced - previous }
            advancedByTab[key] = advanced
            var title = (json["title"] as? String) ?? ""
            if title.hasSuffix(" - YouTube") { title = String(title.dropLast(10)) }
            found.append(ShortsTabStatus(id: key, browser: browser, title: title,
                                         shortsID: json["id"] as? String ?? "",
                                         plays: json["plays"] as? Int ?? 0,
                                         time: json["t"] as? Double ?? 0,
                                         duration: json["d"] as? Double ?? 0,
                                         advanced: advanced,
                                         method: json["method"] as? String ?? ""))
        }
        tabs.removeAll { $0.browser == browser }
        tabs.append(contentsOf: found)
        setupHint = hint
        problem = hint == nil ? firstError.map { "\(browser.name): \($0)" } : nil
    }

    /// Runs an AppleScript through /usr/bin/osascript (a hung browser then can't block the UI).
    private static func runOSAScript(_ script: String, synchronous: Bool,
                                     completion: @escaping (String, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), output = Pipe(), errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            completion("", error.localizedDescription)
            return
        }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        // The completion touches @Observable state, so it must land on the main thread.
        let finish: (String, String?) -> Void = { out, err in
            if Thread.isMainThread { completion(out, err) } else { DispatchQueue.main.async { completion(out, err) } }
        }
        let work = {
            let outData = output.fileHandleForReading.readDataToEndOfFile()
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let out = String(decoding: outData, as: UTF8.self)
            let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let failed = process.terminationStatus != 0 || !err.isEmpty
            finish(out, failed ? (err.isEmpty ? "osascript 종료 코드 \(process.terminationStatus)" : err) : nil)
        }
        if synchronous {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
            work()
        } else {
            DispatchQueue.global(qos: .utility).async {
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if process.isRunning { process.terminate() } }
                work()
            }
        }
    }
}
