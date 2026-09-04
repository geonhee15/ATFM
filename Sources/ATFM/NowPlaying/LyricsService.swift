import AppKit
import Observation
import UniformTypeIdentifiers

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

/// One LRCLIB search hit (or the exact match) the user can pick from.
struct LyricsCandidate: Identifiable, Equatable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let syncedRaw: String?
    let plainRaw: String?
    let source: String

    var isSynced: Bool { !(syncedRaw ?? "").isEmpty }
    var text: String { syncedRaw ?? plainRaw ?? "" }
    var containsHangul: Bool { LyricsService.containsHangul(text) }

    var preview: String {
        let lines = isSynced ? LyricsService.parseLRC(syncedRaw ?? "").map(\.text) : (plainRaw ?? "").components(separatedBy: .newlines)
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    var summary: String {
        let length = duration > 0 ? String(format: " · %d:%02d", Int(duration) / 60, Int(duration) % 60) : ""
        let tag = isSynced ? "싱크" : "일반"
        let snippet = preview.isEmpty ? "" : " · " + String(preview.prefix(22))
        return "[\(tag)] \(trackName) – \(artistName)\(length)\(snippet)"
    }

    func lyrics() -> Lyrics {
        Lyrics(plain: plainRaw.flatMap { $0.isEmpty ? nil : $0 },
               synced: syncedRaw.flatMap { $0.isEmpty ? nil : LyricsService.parseLRC($0) },
               source: source)
    }

    var asObject: [String: Any] {
        var object: [String: Any] = ["id": id, "trackName": trackName, "artistName": artistName, "albumName": albumName,
                                     "duration": duration, "source": source]
        if let syncedRaw { object["syncedLyrics"] = syncedRaw }
        if let plainRaw { object["plainLyrics"] = plainRaw }
        return object
    }
}

/// Lyrics lookup via LRCLIB (https://lrclib.net) with an on-disk cache of the chosen lyrics per song. No key needed.
enum LyricsService {
    private static let base = "https://lrclib.net/api"
    private static let client = "ATFM (https://github.com/geonhee15/ATFM)"

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ATFM/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheKey(title: String, artist: String, duration: Double) -> String {
        Hashing.sha256(Data("\(title)|\(artist)|\(Int(duration.rounded()))".lowercased().utf8))
    }

    private static func cacheFile(_ key: String) -> URL { cacheDirectory.appendingPathComponent(key + ".json") }

    // MARK: Cache (holds whatever is currently chosen for the song: auto pick, user pick, or manual text)

    static func cachedLyrics(key: String) -> Lyrics? {
        guard let data = try? Data(contentsOf: cacheFile(key)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lyrics(from: object)
    }

    static func cache(_ object: [String: Any], key: String) {
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: cacheFile(key), options: .atomic)
        }
    }

    static func clearCache(key: String) {
        try? FileManager.default.removeItem(at: cacheFile(key))
    }

    static func saveManual(text: String, key: String) -> Lyrics? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let synced = parseLRC(trimmed)
        var object: [String: Any] = ["source": "직접 입력"]
        if synced.count >= 2 {
            object["syncedLyrics"] = trimmed
            object["plainLyrics"] = synced.map(\.text).joined(separator: "\n")
        } else {
            object["plainLyrics"] = trimmed
        }
        cache(object, key: key)
        return lyrics(from: object)
    }

    // MARK: Lookup

    /// Collects candidates from several LRCLIB queries and ranks them (synced, duration match, Hangul, exact names).
    static func candidates(title: String, artist: String, album: String, duration: Double) async throws -> [LyricsCandidate] {
        var objects: [[String: Any]] = []
        if let exact = try? await get(title: title, artist: artist, album: album, duration: duration) { objects.append(exact) }
        objects += (try? await search(["track_name": title, "artist_name": artist])) ?? []
        objects += (try? await search(["q": "\(title) \(artist)"])) ?? []
        objects += (try? await search(["track_name": title])) ?? []
        let cleaned = cleanTitle(title)
        if cleaned != title {
            objects += (try? await search(["track_name": cleaned, "artist_name": artist])) ?? []
        }

        var seen = Set<Int>()
        var candidates: [LyricsCandidate] = []
        for object in objects {
            guard let id = object["id"] as? Int, !seen.contains(id) else { continue }
            let synced = (object["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let plain = (object["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let instrumental = object["instrumental"] as? Bool ?? false
            guard synced != nil || plain != nil || instrumental else { continue }
            seen.insert(id)
            candidates.append(LyricsCandidate(
                id: id,
                trackName: object["trackName"] as? String ?? title,
                artistName: object["artistName"] as? String ?? artist,
                albumName: object["albumName"] as? String ?? "",
                duration: (object["duration"] as? Double) ?? 0,
                syncedRaw: synced,
                plainRaw: instrumental && plain == nil ? "♪ 연주곡" : plain,
                source: "LRCLIB"
            ))
        }
        let ranked = candidates.sorted { score($0, title: title, artist: artist, duration: duration) > score($1, title: title, artist: artist, duration: duration) }
        // Many uploads are byte-for-byte the same lyrics; keep the first of each and cap the picker.
        var seenText = Set<String>()
        var unique: [LyricsCandidate] = []
        for candidate in ranked {
            let signature = Hashing.sha256(Data(candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            guard !seenText.contains(signature) else { continue }
            seenText.insert(signature)
            unique.append(candidate)
            if unique.count >= 12 { break }
        }
        return unique
    }

    static func score(_ candidate: LyricsCandidate, title: String, artist: String, duration: Double) -> Double {
        var score = 0.0
        if candidate.isSynced { score += 100 }
        if duration > 0, candidate.duration > 0 {
            let delta = abs(candidate.duration - duration)
            score += delta <= 2 ? 40 : (delta <= 5 ? 20 : (delta <= 15 ? 5 : -40))
        }
        if candidate.containsHangul { score += 30 }   // prefer 한글 over romanized uploads
        if candidate.trackName.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { score += 15 }
        if candidate.artistName.compare(artist, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { score += 10 }
        if candidate.plainRaw != nil { score += 5 }
        return score
    }

    static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
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

    private static func search(_ query: [String: String]) async throws -> [[String: Any]] {
        let (data, response) = try await URLSession.shared.data(for: request("/search", query: query))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    static func lyrics(from object: [String: Any]) -> Lyrics? {
        let source = object["source"] as? String ?? "LRCLIB"
        if object["instrumental"] as? Bool == true { return Lyrics(plain: "♪ 연주곡", synced: nil, source: source) }
        let plain = (object["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let synced = (object["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : parseLRC($0) }
        let result = Lyrics(plain: plain, synced: synced, source: source)
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
    private(set) var candidates: [LyricsCandidate] = []
    private(set) var selectedCandidateID: Int?
    private(set) var isLoadingCandidates = false
    var isEditing = false
    var draft = ""
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
        candidates = []
        selectedCandidateID = nil
        isEditing = false
        state = memory[newKey] ?? .idle
        if autoFetch { ensureLoaded() }
    }

    private var cacheKey: String? {
        guard let track = monitor.track else { return nil }
        return LyricsService.cacheKey(title: track.title, artist: track.artist, duration: track.duration)
    }

    func ensureLoaded() {
        guard let track = monitor.track, let cacheKey else { return }
        let currentKey = key(for: track)
        if trackKey != currentKey {
            trackKey = currentKey
            offset = offsets[currentKey] ?? 0
            candidates = []
            selectedCandidateID = nil
            state = memory[currentKey] ?? .idle
        }
        if case .idle = state {} else { return }
        if let cached = LyricsService.cachedLyrics(key: cacheKey) {
            state = .found(cached)
            memory[currentKey] = state
            return
        }
        state = .loading
        task?.cancel()
        task = Task { [weak self] in
            do {
                let found = try await LyricsService.candidates(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
                guard !Task.isCancelled, let self, self.trackKey == currentKey else { return }
                self.candidates = found
                if let best = found.first {
                    LyricsService.cache(best.asObject, key: cacheKey)
                    self.selectedCandidateID = best.id
                    self.state = .found(best.lyrics())
                } else {
                    self.state = .notFound
                }
                self.memory[currentKey] = self.state
            } catch {
                guard !Task.isCancelled, let self, self.trackKey == currentKey else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Fetches the candidate list for the picker (used when the song came from the cache).
    func loadCandidates() {
        guard let track = monitor.track, !isLoadingCandidates else { return }
        let currentKey = key(for: track)
        isLoadingCandidates = true
        Task { [weak self] in
            let found = (try? await LyricsService.candidates(title: track.title, artist: track.artist, album: track.album, duration: track.duration)) ?? []
            guard let self, self.trackKey == currentKey else { return }
            self.candidates = found
            self.isLoadingCandidates = false
        }
    }

    func choose(_ candidate: LyricsCandidate) {
        guard let cacheKey else { return }
        LyricsService.cache(candidate.asObject, key: cacheKey)
        selectedCandidateID = candidate.id
        state = .found(candidate.lyrics())
        memory[trackKey] = state
    }

    /// Drops the cached choice and searches again from scratch.
    func retry() {
        if let cacheKey { LyricsService.clearCache(key: cacheKey) }
        memory[trackKey] = nil
        candidates = []
        selectedCandidateID = nil
        state = .idle
        ensureLoaded()
    }

    func beginEditing() {
        draft = lyrics.map { lyrics -> String in
            if let synced = lyrics.synced, !synced.isEmpty {
                return synced.map { line in
                    let minutes = Int(line.time) / 60
                    let seconds = line.time - Double(minutes * 60)
                    return String(format: "[%02d:%05.2f] %@", minutes, seconds, line.text as NSString)
                }.joined(separator: "\n")
            }
            return lyrics.plain ?? ""
        } ?? ""
        isEditing = true
    }

    func saveDraft() {
        guard let cacheKey else { return }
        if let saved = LyricsService.saveManual(text: draft, key: cacheKey) {
            selectedCandidateID = nil
            state = .found(saved)
            memory[trackKey] = state
        }
        isEditing = false
    }

    func importLRCFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = "가사 파일(.lrc 또는 .txt)을 고르세요"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self, let cacheKey = self.cacheKey else { return }
                guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16)) else { return }
                if let saved = LyricsService.saveManual(text: text, key: cacheKey) {
                    self.selectedCandidateID = nil
                    self.state = .found(saved)
                    self.memory[self.trackKey] = self.state
                }
            }
        }
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
