import AppKit
import Observation

struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var rate: Double
    var timestamp: Date?
    var isPlaying: Bool
    var pid: pid_t
    var sourceBundleID: String?
    var sourceName: String?
    var hasArtwork: Bool

    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    var isSpotifyApp: Bool { sourceBundleID == "com.spotify.client" }
    var isBrowser: Bool {
        guard let id = sourceBundleID else { return false }
        return Self.browserBundleIDs.contains(id) || id.lowercased().contains("chrome") || id.lowercased().contains("browser")
    }

    /// Elapsed seconds extrapolated from the last MediaRemote timestamp.
    func currentElapsed(at now: Date) -> Double {
        guard isPlaying, let timestamp else { return elapsed }
        let value = elapsed + now.timeIntervalSince(timestamp) * max(rate, 0)
        return duration > 0 ? min(duration, value) : value
    }
}

/// Streams Now Playing state from the perl-hosted MediaRemote bridge and sends transport commands back.
@MainActor
@Observable
final class NowPlayingMonitor {
    private(set) var track: NowPlayingTrack?
    private(set) var artwork: NSImage?
    private(set) var isBridgeRunning = false
    private(set) var lastError: String?
    /// Ticks once a second so progress bars can animate without new bridge messages.
    private(set) var now = Date()

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var stopping = false

    func start() {
        guard process == nil else { return }
        stopping = false
        launchBridge()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func stop() {
        stopping = true
        ticker?.invalidate()
        ticker = nil
        if let process, process.isRunning {
            try? stdin?.close()
            process.terminate()
        }
        process = nil
        isBridgeRunning = false
    }

    // MARK: Commands

    func send(_ command: String) {
        guard let stdin, let data = (command + "\n").data(using: .utf8) else { return }
        try? stdin.write(contentsOf: data)
    }

    func togglePlayPause() { send("toggle") }
    func next() { send("next") }
    func previous() { send("prev") }
    func seek(to seconds: Double) { send("seek \(Int(seconds))") }

    // MARK: Bridge process

    static var bridgeResources: (script: URL, dylib: URL)? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote.pl")
        let dylib = resources.appendingPathComponent("ATFMMediaRemote.dylib")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: dylib.path) else { return nil }
        return (script, dylib)
    }

    private func launchBridge() {
        guard let resources = Self.bridgeResources else {
            lastError = "브리지 파일(mediaremote.pl / ATFMMediaRemote.dylib)을 찾지 못했어요"
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.script.path, resources.dylib.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(data) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.bridgeExited(status: finished.terminationStatus) }
            }
        }
        do {
            try process.run()
            self.process = process
            stdin = input.fileHandleForWriting
            startedAt = Date()
            isBridgeRunning = true
            lastError = nil
        } catch {
            lastError = "브리지를 시작하지 못했어요: \(error.localizedDescription)"
        }
    }

    private func bridgeExited(status: Int32) {
        isBridgeRunning = false
        process = nil
        stdin = nil
        track = nil
        artwork = nil
        guard !stopping else { return }
        // Restart with a little backoff; give up after repeated immediate failures.
        if let startedAt, Date().timeIntervalSince(startedAt) > 30 { restartAttempts = 0 }
        restartAttempts += 1
        guard restartAttempts <= 5 else {
            lastError = "브리지가 계속 종료돼요 (status \(status))"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restartAttempts) * 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopping, self.process == nil else { return }
                self.launchBridge()
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let error = object["error"] as? String {
            lastError = error
            return
        }
        if object["empty"] as? Bool == true {
            track = nil
            artwork = nil
            return
        }
        let pid = pid_t((object["pid"] as? Int) ?? 0)
        let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
        let timestamp = (object["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let title = object["title"] as? String ?? ""
        let artist = object["artist"] as? String ?? ""
        guard !title.isEmpty || !artist.isEmpty else {
            track = nil
            artwork = nil
            return
        }
        let updated = NowPlayingTrack(
            title: title,
            artist: artist,
            album: object["album"] as? String ?? "",
            duration: object["duration"] as? Double ?? 0,
            elapsed: object["elapsed"] as? Double ?? 0,
            rate: object["rate"] as? Double ?? 0,
            timestamp: timestamp,
            isPlaying: object["playing"] as? Bool ?? false,
            pid: pid,
            sourceBundleID: app?.bundleIdentifier,
            sourceName: app?.localizedName,
            hasArtwork: object["hasArtwork"] as? Bool ?? false
        )
        if let base64 = object["artwork"] as? String, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            artwork = image
        } else if updated.hasArtwork == false {
            artwork = nil
        }
        if updated != track { track = updated }
        now = Date()
    }
}
