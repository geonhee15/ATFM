import Foundation
import Observation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

struct Lyrics: Equatable {
    let plain: String?
    let synced: [LyricLine]?
    let source: String
    var isSynced: Bool { !(synced ?? []).isEmpty }
    var isEmpty: Bool { !isSynced && (plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum LyricsState: Equatable {
    case idle
    case loading
    case found(Lyrics)
    case notFound
    case failed(String)
}

/// Lyrics lookup via LRCLIB (https://lrclib.net) with an on-disk cache. No key needed.
enum LyricsService {
    private static let base = "https://lrclib.net/api"
    private static let client = "ATFM (https://github.com/geonhee15/ATFM)"

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ATFM/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheKey(title: String, artist: String, album: String, duration: Double) -> String {
        Hashing.sha256(Data("\(title)|\(artist)|\(album)|\(Int(duration.rounded()))".lowercased().utf8))
    }

    static func fetch(title: String, artist: String, album: String, duration: Double) async throws -> Lyrics? {
        let key = cacheKey(title: title, artist: artist, album: album, duration: duration)
        let cacheFile = cacheDirectory.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: cacheFile),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return lyrics(from: object)
        }

        var candidate = try await get(title: title, artist: artist, album: album, duration: duration)
        if candidate == nil {
            candidate = try await search(title: title, artist: artist, duration: duration)
        }
        if candidate == nil {
            // Retry with a cleaned title ("(feat. …)", "- Remastered" etc. often break exact matching).
            let cleaned = cleanTitle(title)
            if cleaned != title {
                candidate = try await search(title: cleaned, artist: artist, duration: duration)
            }
        }
        guard let object = candidate else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: cacheFile, options: .atomic)
        }
        return lyrics(from: object)
    }

    private static func request(_ path: String, query: [String: String]) -> URLRequest {
        var components = URLComponents(string: base + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue(client, forHTTPHeaderField: "Lrclib-Client")
        request.setValue(client, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    private static func get(title: String, artist: String, album: String, duration: Double) async throws -> [String: Any]? {
        var query = ["track_name": title, "artist_name": artist, "duration": String(Int(duration.rounded()))]
        if !album.isEmpty { query["album_name"] = album }
        let (data, response) = try await URLSession.shared.data(for: request("/get", query: query))
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw LyricsError.http(http.statusCode) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func search(title: String, artist: String, duration: Double) async throws -> [String: Any]? {
        let (data, response) = try await URLSession.shared.data(for: request("/search", query: ["track_name": title, "artist_name": artist]))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !results.isEmpty else { return nil }
        // Prefer synced lyrics whose duration is close to ours.
        func score(_ item: [String: Any]) -> Double {
            let synced = (item["syncedLyrics"] as? String)?.isEmpty == false ? 100.0 : 0
            let itemDuration = (item["duration"] as? Double) ?? 0
            let closeness = duration > 0 && itemDuration > 0 ? max(0, 30 - abs(itemDuration - duration)) : 0
            return synced + closeness
        }
        return results.max { score($0) < score($1) }
    }

    private static func lyrics(from object: [String: Any]) -> Lyrics? {
        if object["instrumental"] as? Bool == true { return Lyrics(plain: "♪ 연주곡", synced: nil, source: "LRCLIB") }
        let plain = (object["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let synced = (object["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : parseLRC($0) }
        let result = Lyrics(plain: plain, synced: synced, source: "LRCLIB")
        return result.isEmpty ? nil : result
    }

    static func cleanTitle(_ title: String) -> String {
        var text = title
        for pattern in [#"\s*[\(\[][^\)\]]*(feat|ft\.|with|remaster|version|edit|mix|live)[^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Parses "[mm:ss.xx] text" lines (multiple timestamps per line allowed) into a time-sorted list.
    static func parseLRC(_ text: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#) else { return [] }
        var entries: [(Double, String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let textStart = matches.last!.range.location + matches.last!.range.length
            let lyric = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: match.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                entries.append((minutes * 60 + seconds + fraction, lyric))
            }
        }
        return entries.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

enum LyricsError: LocalizedError {
    case http(Int)
    var errorDescription: String? {
        if case .http(let code) = self { return "가사 서버 오류 (\(code))" }
        return nil
    }
}

/// Keeps lyrics for the current track and computes the active synced line.
@MainActor
@Observable
final class LyricsController {
    private(set) var state: LyricsState = .idle
    /// Per-track sync correction in seconds; positive shows lines earlier.
    private(set) var offset: Double = 0
    /// Fetch automatically whenever the track changes (true while the lyrics box is open).
    var autoFetch = false { didSet { if autoFetch { ensureLoaded() } } }

    let monitor: NowPlayingMonitor
    @ObservationIgnored private var trackKey = ""
    @ObservationIgnored private var memory: [String: LyricsState] = [:]
    @ObservationIgnored private var offsets: [String: Double]
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let offsetsKey = "lyricsOffsets"
    static let offsetStep = 0.5

    init(monitor: NowPlayingMonitor) {
        self.monitor = monitor
        offsets = (UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: Double]) ?? [:]
        if let track = monitor.track {
            trackKey = "\(track.title)|\(track.artist)|\(Int(track.duration.rounded()))".lowercased()
            offset = offsets[trackKey] ?? 0
        }
        observe()
    }

    // MARK: Sync offset

    var offsetLabel: String {
        offset == 0 ? "0.0s" : String(format: "%@%.1fs", offset > 0 ? "+" : "−", abs(offset))
    }

    func adjustOffset(by delta: Double) {
        setOffset(offset + delta)
    }

    func resetOffset() { setOffset(0) }

    private func setOffset(_ value: Double) {
        let rounded = (value / Self.offsetStep).rounded() * Self.offsetStep
        offset = max(-30, min(30, rounded))
        guard !trackKey.isEmpty else { return }
        if offset == 0 { offsets[trackKey] = nil } else { offsets[trackKey] = offset }
        if offsets.count > 300 {   // keep the map small; drop arbitrary extras
            for key in offsets.keys.prefix(offsets.count - 300) { offsets[key] = nil }
        }
        UserDefaults.standard.set(offsets, forKey: Self.offsetsKey)
    }

    private func observe() {
        withObservationTracking {
            _ = monitor.track?.title
            _ = monitor.track?.artist
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.trackChanged()
                self?.observe()
            }
        }
    }

    private func key(for track: NowPlayingTrack) -> String {
        "\(track.title)|\(track.artist)|\(Int(track.duration.rounded()))".lowercased()
    }

    private func trackChanged() {
        guard let track = monitor.track else {
            task?.cancel()
            trackKey = ""
            state = .idle
            return
        }
        let newKey = key(for: track)
        guard newKey != trackKey else { return }
        trackKey = newKey
        offset = offsets[newKey] ?? 0
        task?.cancel()
        state = memory[newKey] ?? .idle
        if autoFetch { ensureLoaded() }
    }

    func ensureLoaded() {
        guard let track = monitor.track else { return }
        let currentKey = key(for: track)
        if trackKey != currentKey {
            trackKey = currentKey
            offset = offsets[currentKey] ?? 0
            state = memory[currentKey] ?? .idle
        }
        if case .idle = state {} else { return }
        state = .loading
        task?.cancel()
        task = Task { [weak self] in
            do {
                let lyrics = try await LyricsService.fetch(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
                guard !Task.isCancelled, let self, self.trackKey == currentKey else { return }
                let result: LyricsState = lyrics.map { .found($0) } ?? .notFound
                self.memory[currentKey] = result
                self.state = result
            } catch {
                guard !Task.isCancelled, let self, self.trackKey == currentKey else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        if let track = monitor.track { memory[key(for: track)] = nil }
        state = .idle
        ensureLoaded()
    }

    var lyrics: Lyrics? {
        if case .found(let lyrics) = state { return lyrics }
        return nil
    }

    func currentLineIndex(at now: Date) -> Int? {
        guard let lines = lyrics?.synced, !lines.isEmpty, let track = monitor.track else { return nil }
        let elapsed = track.currentElapsed(at: now) + offset
        var index: Int?
        for line in lines where line.time <= elapsed { index = line.id }
        return index
    }

    func seek(to line: LyricLine) {
        monitor.seek(to: max(0, line.time - offset))
    }
}
