import AppKit
import Observation

struct PlaylistSegment: Identifiable, Codable, Equatable {
    let id: Int
    var start: Double
    var end: Double?
    var raw: String
    var title: String
    var artist: String

    var timeLabel: String {
        let total = Int(start)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    var display: String { artist.isEmpty ? title : "\(title) — \(artist)" }
}

struct PlaylistAnalysis: Codable, Equatable {
    let videoID: String
    let videoTitle: String
    let channel: String
    let duration: Double
    let source: String
    let usedAI: Bool
    var segments: [PlaylistSegment]
    let createdAt: Date
}

/// Turns a YouTube music compilation (playing in the browser) into a timestamped track list:
/// browser tab → video ID → yt-dlp metadata (chapters, description, pinned + top comments) →
/// timestamp parsing → one optional Gemini call to name the original songs → LRCLIB lyrics per song,
/// fetched lazily as the video reaches each song. Results are cached per video on disk.
@MainActor
@Observable
final class PlaylistAnalyzer {
    enum State: Equatable {
        case idle, locating, fetching, resolving, ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var analysis: PlaylistAnalysis?
    private(set) var forTrackTitle: String?
    private(set) var lyrics: [Int: Lyrics] = [:]
    private(set) var lyricsLoading: Set<Int> = []
    private(set) var lyricsMissing: Set<Int> = []
    /// Per-song lyric sync nudge (seconds), like the lyrics box offset.
    private(set) var lyricOffsets: [Int: Double] = [:]

    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var generation = 0

    init(directory: URL? = nil) {
        let base = directory ?? {
            if let override = ProcessInfo.processInfo.environment["ATFM_DEBUG_DATA_DIR"], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ATFM", isDirectory: true)
        }()
        cacheDirectory = base.appendingPathComponent("playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Skip the browser lookup (probe / known URL).
    func analyzeVideo(id videoID: String, trackTitle: String = "") {
        guard !isBusy else { return }
        generation += 1
        forTrackTitle = trackTitle
        analysis = nil
        lyrics = [:]
        lyricsLoading = []
        lyricsMissing = []
        load(videoID: videoID, token: generation)
    }

    /// Screenshot helper: a made-up compilation with lyrics for the current song.
    func debugInjectSample() {
        generation += 1
        let names: [(String, String)] = [("Boat", "Ed Sheeran"), ("Symphony", "Clean Bandit"), ("When I Was Your Man", "Bruno Mars"),
                                         ("Complicated", "Avril Lavigne"), ("All I Want for Christmas Is You", "Mariah Carey"),
                                         ("Snowman", "Sia"), ("Santa Tell Me", "Ariana Grande"), ("drivers license", "Olivia Rodrigo")]
        let starts: [Double] = [0, 175, 373, 596, 751, 955, 1116, 1316]
        var segments: [PlaylistSegment] = []
        for (index, name) in names.enumerated() {
            segments.append(PlaylistSegment(id: index, start: starts[index], end: index + 1 < starts.count ? starts[index + 1] : 1560,
                                            raw: name.0, title: name.0, artist: name.1))
        }
        analysis = PlaylistAnalysis(videoID: "sample", videoTitle: "🎧 겨울 감성 팝송 플레이리스트", channel: "ATFM", duration: 1560,
                                    source: "고정 댓글", usedAI: true, segments: segments, createdAt: Date())
        forTrackTitle = "Midnight Drive"
        let lines = ["I don't wanna fade away", "But I can't take another day", "The tides are rising, still I try", "To keep the boat afloat tonight"]
        lyrics[0] = Lyrics(plain: nil, synced: lines.enumerated().map { LyricLine(id: $0.offset, time: 60 + Double($0.offset) * 4, text: $0.element) }, source: "LRCLIB")
        state = .ready
    }

    var isBusy: Bool {
        switch state {
        case .locating, .fetching, .resolving: return true
        default: return false
        }
    }

    // MARK: Entry points

    func analyze(track: NowPlayingTrack) {
        guard !isBusy else { return }
        generation += 1
        let token = generation
        forTrackTitle = track.title
        analysis = nil
        lyrics = [:]
        lyricsLoading = []
        lyricsMissing = []
        state = .locating
        AppleScriptRunner.browserTabs { [weak self] tabs, error in
            guard let self, self.generation == token else { return }
            guard let videoID = Self.matchVideo(tabs: tabs, trackTitle: track.title) else {
                if let error, tabs.isEmpty {
                    self.state = .failed(error)
                } else if tabs.contains(where: { Self.videoID(from: $0.url) != nil }) {
                    self.state = .failed("YouTube 탭이 여러 개라 재생 중인 영상을 못 골랐어요. 다른 YouTube 탭을 닫고 다시 눌러 주세요.")
                } else {
                    self.state = .failed("열려 있는 YouTube 영상 탭을 찾지 못했어요 (youtube.com/watch 주소여야 해요)")
                }
                return
            }
            self.load(videoID: videoID, token: token)
        }
    }

    func clear() {
        generation += 1
        process?.terminate()
        process = nil
        state = .idle
        analysis = nil
        forTrackTitle = nil
        lyrics = [:]
        lyricsLoading = []
        lyricsMissing = []
    }

    func segment(at elapsed: Double) -> PlaylistSegment? {
        guard let segments = analysis?.segments, !segments.isEmpty else { return nil }
        var current: PlaylistSegment?
        for segment in segments where segment.start <= elapsed + 0.5 { current = segment }
        return current ?? segments.first
    }

    func nextSegment(after segment: PlaylistSegment) -> PlaylistSegment? {
        analysis?.segments.first { $0.id == segment.id + 1 }
    }

    func adjustOffset(for segment: PlaylistSegment, by delta: Double) {
        lyricOffsets[segment.id, default: 0] += delta
    }

    func offset(for segment: PlaylistSegment) -> Double { lyricOffsets[segment.id] ?? 0 }

    // MARK: Locate the video in the browser

    static func matchVideo(tabs: [(url: String, title: String)], trackTitle: String) -> String? {
        let wanted = normalize(trackTitle)
        let youtube = tabs.compactMap { tab -> (id: String, title: String)? in
            guard let id = videoID(from: tab.url) else { return nil }
            return (id, tab.title)
        }
        if let exact = youtube.first(where: { normalize($0.title).contains(wanted) || wanted.contains(normalize($0.title).replacingOccurrences(of: "youtube", with: "")) && !wanted.isEmpty }) {
            return exact.id
        }
        return youtube.count == 1 ? youtube[0].id : nil
    }

    static func videoID(from url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return nil }
        if host.contains("youtube.com"), components.path.hasPrefix("/watch") {
            return components.queryItems?.first { $0.name == "v" }?.value
        }
        if host == "youtu.be" {
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " - youtube", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    // MARK: Fetch metadata (cache → yt-dlp)

    private func cacheURL(_ videoID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(videoID).json")
    }

    private func load(videoID: String, token: Int) {
        if let data = try? Data(contentsOf: cacheURL(videoID)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let cached = try? decoder.decode(PlaylistAnalysis.self, from: data), !cached.segments.isEmpty {
                analysis = cached
                state = .ready
                return
            }
        }
        state = .fetching
        guard let ytdlp = Self.locateYTDLP() else {
            state = .failed("yt-dlp가 없어요 (brew install yt-dlp)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = ["--skip-download", "--no-playlist", "--no-warnings", "--dump-single-json", "--write-comments",
                             "--extractor-args", "youtube:comment_sort=top;max_comments=60,60,0,0",
                             "https://www.youtube.com/watch?v=\(videoID)"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"
        process.environment = environment
        let output = Pipe(), errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            state = .failed("yt-dlp 실행 실패: \(error.localizedDescription)")
            return
        }
        self.process = process
        // The JSON is several hundred KB: drain stdout while yt-dlp runs or the pipe fills up and it hangs.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.process = nil
                guard status == 0, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let line = errorText.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? "영상 정보를 받지 못했어요"
                    self.state = .failed(line.replacingOccurrences(of: "ERROR: ", with: ""))
                    return
                }
                self.resolve(videoID: videoID, json: json, token: token)
            }
        }
    }

    private static func locateYTDLP() -> String? {
        ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/opt/local/bin/yt-dlp"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Extract the track list

    private func resolve(videoID: String, json: [String: Any], token: Int) {
        let title = json["title"] as? String ?? ""
        let channel = json["channel"] as? String ?? json["uploader"] as? String ?? ""
        let duration = json["duration"] as? Double ?? 0
        var candidates: [(source: String, items: [(Double, String)], priority: Int)] = []

        if let chapters = json["chapters"] as? [[String: Any]] {
            let items = chapters.compactMap { chapter -> (Double, String)? in
                guard let start = chapter["start_time"] as? Double, let name = chapter["title"] as? String else { return nil }
                return (start, name)
            }
            if items.count >= 3 { candidates.append(("챕터", items, 3)) }
        }
        if let description = json["description"] as? String {
            let items = Self.parseTimestamps(description)
            if items.count >= 3 { candidates.append(("영상 설명", items, 2)) }
        }
        if let comments = json["comments"] as? [[String: Any]] {
            let sorted = comments.sorted {
                let pinnedA = ($0["is_pinned"] as? Bool ?? false) ? 1 : 0, pinnedB = ($1["is_pinned"] as? Bool ?? false) ? 1 : 0
                if pinnedA != pinnedB { return pinnedA > pinnedB }
                return ($0["like_count"] as? Int ?? 0) > ($1["like_count"] as? Int ?? 0)
            }
            for comment in sorted.prefix(40) {
                guard let text = comment["text"] as? String else { continue }
                let items = Self.parseTimestamps(text)
                guard items.count >= 3 else { continue }
                let pinned = comment["is_pinned"] as? Bool ?? false
                let author = comment["author"] as? String ?? "댓글"
                candidates.append((pinned ? "고정 댓글" : "댓글 \(author)", items, pinned ? 2 : 1))
            }
        }
        // Best list: most entries wins, ties (within 80 %) broken by source priority.
        guard let best = candidates.sorted(by: { a, b in
            if Double(min(a.items.count, b.items.count)) >= 0.8 * Double(max(a.items.count, b.items.count)) {
                return a.priority > b.priority
            }
            return a.items.count > b.items.count
        }).first else {
            state = .failed("타임스탬프 목록을 찾지 못했어요 (설명·댓글에 0:00 형식이 없음)")
            return
        }
        var segments: [PlaylistSegment] = []
        for (index, item) in best.items.enumerated() {
            let (songTitle, artist) = Self.splitTitleArtist(item.1)
            segments.append(PlaylistSegment(id: index, start: item.0,
                                            end: index + 1 < best.items.count ? best.items[index + 1].0 : (duration > 0 ? duration : nil),
                                            raw: item.1, title: songTitle, artist: artist))
        }
        let draft = PlaylistAnalysis(videoID: videoID, videoTitle: title, channel: channel, duration: duration,
                                     source: best.source, usedAI: false, segments: segments, createdAt: Date())
        let needsAI = segments.filter { $0.artist.isEmpty }.count > segments.count / 3
        let hasKey = !(UserDefaults.standard.string(forKey: "geminiAPIKey") ?? "").isEmpty
        guard needsAI, hasKey else {
            finish(draft, token: token)
            return
        }
        state = .resolving
        let snippet = String((json["description"] as? String ?? "").prefix(400))
        Task { [weak self] in
            let resolved = await Self.resolveWithGemini(draft, descriptionSnippet: snippet)
            guard let self, self.generation == token else { return }
            self.finish(resolved ?? draft, token: token)
        }
    }

    private func finish(_ result: PlaylistAnalysis, token: Int) {
        analysis = result
        state = .ready
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result) { try? data.write(to: cacheURL(result.videoID), options: .atomic) }
    }

    private static let timestampRegex = try! NSRegularExpression(pattern: #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])"#)

    /// "0:00 boat" / "[2:55] SYMPHONY" / "6:13 - When i was your man" / "boat 0:00" → (seconds, label)
    static func parseTimestamps(_ text: String) -> [(Double, String)] {
        var items: [(Double, String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            let matches = timestampRegex.matches(in: line, range: range)
            guard let first = matches.first else { continue }
            func number(_ index: Int) -> Int {
                guard let r = Range(first.range(at: index), in: line) else { return 0 }
                return Int(line[r]) ?? 0
            }
            let seconds = Double(number(1) * 3600 + number(2) * 60 + number(3))
            var label = line
            for match in matches.reversed() {
                if let r = Range(match.range, in: label) { label.removeSubrange(r) }
            }
            label = label.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—|~:•·►▶[]()【】「」＊*.,")).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.count <= 120 else { continue }
            items.append((seconds, label))
        }
        // Keep the list monotonic (drop stray earlier timestamps) and unique.
        var out: [(Double, String)] = []
        var last = -1.0
        for item in items where item.0 >= last {
            out.append(item)
            last = item.0
        }
        return out
    }

    /// "Artist - Title" is the most common written form; keep both halves so AI or LRCLIB can sort it out.
    static func splitTitleArtist(_ label: String) -> (String, String) {
        for separator in [" - ", " – ", " — ", " | ", " / ", " _ "] {
            let parts = label.components(separatedBy: separator)
            if parts.count == 2 {
                return (parts[1].trimmingCharacters(in: .whitespaces), parts[0].trimmingCharacters(in: .whitespaces))
            }
        }
        return (label, "")
    }

    // MARK: One Gemini call to name the original songs

    private static func resolveWithGemini(_ draft: PlaylistAnalysis, descriptionSnippet: String) async -> PlaylistAnalysis? {
        let lines = draft.segments.map { "\($0.id): \($0.raw)" }.joined(separator: "\n")
        let prompt = """
        A YouTube music compilation video and its track list (timestamps already removed).
        Video title: \(draft.videoTitle)
        Channel: \(draft.channel)
        Description: \(descriptionSnippet.replacingOccurrences(of: "\n", with: " "))
        Lines:
        \(lines)
        For each line return the ORIGINAL song title and the ORIGINAL performing artist (not the uploader or cover singer) so lyrics can be looked up. If the artist is unknown use "". Fix casing/typos in titles. Keep every index.
        Answer with ONLY a JSON array like [{"i":0,"title":"Boat","artist":"Ed Sheeran"}].
        """
        guard let text = try? await GeminiQuick.generate(prompt: prompt) else { return nil }
        let cleaned = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"),
              let data = String(cleaned[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var segments = draft.segments
        for item in array {
            guard let index = item["i"] as? Int, let position = segments.firstIndex(where: { $0.id == index }) else { continue }
            if let title = item["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty { segments[position].title = title.trimmingCharacters(in: .whitespaces) }
            if let artist = item["artist"] as? String { segments[position].artist = artist.trimmingCharacters(in: .whitespaces) }
        }
        return PlaylistAnalysis(videoID: draft.videoID, videoTitle: draft.videoTitle, channel: draft.channel, duration: draft.duration,
                                source: draft.source, usedAI: true, segments: segments, createdAt: draft.createdAt)
    }

    // MARK: Lyrics per song (lazy)

    func ensureLyrics(for segment: PlaylistSegment) {
        guard lyrics[segment.id] == nil, !lyricsLoading.contains(segment.id), !lyricsMissing.contains(segment.id) else { return }
        let duration = segment.end.map { max(0, $0 - segment.start) } ?? 0
        let key = LyricsService.cacheKey(title: segment.title, artist: segment.artist, duration: duration)
        if let cached = LyricsService.cachedLyrics(key: key) {
            lyrics[segment.id] = cached
            return
        }
        lyricsLoading.insert(segment.id)
        let token = generation
        Task { [weak self] in
            let candidates = (try? await LyricsService.candidates(title: segment.title, artist: segment.artist, album: "", duration: duration)) ?? []
            guard let self, self.generation == token else { return }
            self.lyricsLoading.remove(segment.id)
            if let best = candidates.first {
                let found = best.lyrics()
                self.lyrics[segment.id] = found
                LyricsService.cache(best.asObject, key: key)
            } else {
                self.lyricsMissing.insert(segment.id)
            }
        }
    }
}
