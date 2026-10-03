import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

enum AudioExportFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, wav, flac, aiff, ogg
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp3: return "MP3"
        case .m4a: return "M4A (AAC)"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        case .aiff: return "AIFF"
        case .ogg: return "OGG (Opus)"
        }
    }
    var ext: String { rawValue }
    var isLossy: Bool { self == .mp3 || self == .m4a || self == .ogg }

    func codecArguments(bitrate: Int) -> [String] {
        switch self {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
        case .m4a: return ["-c:a", "aac", "-b:a", "\(bitrate)k"]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .flac: return ["-c:a", "flac"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        case .ogg: return ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"]
        }
    }
}

/// Everything the editor can do to a file. Times are seconds in the source file.
struct AudioEditSettings: Equatable {
    var start: Double = 0
    var end: Double = 0
    var speed: Double = 1
    var keepPitch = true
    var gainDB: Double = 0
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var normalize = false
    var reverse = false

    var selectedDuration: Double { max(0, end - start) }
    var outputDuration: Double { selectedDuration / max(speed, 0.01) }

    /// ffmpeg audio filters, in order: reverse → speed → loudness → gain → fades.
    func filterChain(sampleRate: Int) -> [String] {
        var filters: [String] = []
        if reverse { filters.append("areverse") }
        if abs(speed - 1) > 0.0005 {
            if keepPitch {
                filters += Self.atempoChain(speed)
            } else {
                // Tape-style: pitch follows the speed.
                filters += ["aresample=\(sampleRate)", String(format: "asetrate=%.2f", Double(sampleRate) * speed), "aresample=\(sampleRate)"]
            }
        }
        if normalize { filters += ["loudnorm=I=-16:TP=-1.5:LRA=11", "aresample=\(sampleRate)"] }
        if abs(gainDB) > 0.05 { filters.append(String(format: "volume=%.1fdB", gainDB)) }
        let out = outputDuration
        let fadeInLength = min(fadeIn, out / 2), fadeOutLength = min(fadeOut, out / 2)
        if fadeInLength > 0.01 { filters.append(String(format: "afade=t=in:st=0:d=%.3f", fadeInLength)) }
        if fadeOutLength > 0.01 { filters.append(String(format: "afade=t=out:st=%.3f:d=%.3f", max(0, out - fadeOutLength), fadeOutLength)) }
        return filters
    }

    /// atempo accepts 0.5–2.0 per instance on older ffmpeg builds, so larger changes are chained.
    static func atempoChain(_ speed: Double) -> [String] {
        var filters: [String] = []
        var remaining = speed
        while remaining > 2.0 + 1e-9 { filters.append("atempo=2.0"); remaining /= 2 }
        while remaining < 0.5 - 1e-9 { filters.append("atempo=0.5"); remaining /= 0.5 }
        if abs(remaining - 1) > 0.0005 { filters.append(String(format: "atempo=%.4f", remaining)) }
        return filters
    }

    func arguments(input: URL, output: URL, format: AudioExportFormat, bitrate: Int, sampleRate: Int, fullDuration: Double) -> [String] {
        var args = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        if start > 0.005 { args += ["-ss", String(format: "%.3f", start)] }
        if end < fullDuration - 0.005 { args += ["-t", String(format: "%.3f", selectedDuration)] }
        args += ["-i", input.path, "-vn", "-map_metadata", "0"]
        let filters = filterChain(sampleRate: sampleRate)
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        args += format.codecArguments(bitrate: bitrate)
        args.append(output.path)
        return args
    }
}

/// 오디오 편집기: load a file, trim it on the waveform, change speed / volume / fades, convert and export.
/// Live preview runs through AVAudioEngine (trim · speed · pitch · gain); export goes through ffmpeg.
@MainActor
@Observable
final class AudioEditor {
    struct Source: Equatable {
        let url: URL                 // the file the user opened (export reads this)
        let playURL: URL             // what AVAudioFile reads: the same file, or a decoded temp copy
        let duration: Double
        let sampleRate: Double
        let channels: Int
        let fileSize: UInt64
        var name: String { url.lastPathComponent }
        var formatName: String { url.pathExtension.uppercased() }
    }

    enum Location: String { case sameFolder, downloads }
    enum ResultPreview: Equatable { case idle, rendering(Double), playing }

    private(set) var source: Source?
    private(set) var waveform: [Float] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    var settings = AudioEditSettings() {
        didSet { if settings != oldValue { applyLiveSettings() } }
    }
    var loop = false

    var format: AudioExportFormat { didSet { UserDefaults.standard.set(format.rawValue, forKey: "audioEditFormat") } }
    var bitrate: Int { didSet { UserDefaults.standard.set(bitrate, forKey: "audioEditBitrate") } }
    var location: Location { didSet { UserDefaults.standard.set(location.rawValue, forKey: "audioEditLocation") } }

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var exportProgress: Double?
    private(set) var exportError: String?
    private(set) var lastOutput: URL?
    private(set) var resultPreview: ResultPreview = .idle

    @ObservationIgnored var notify: ((String, String) -> Void)?
    @ObservationIgnored let ffmpeg = FFmpegConverter.locate()
    var hasFFmpeg: Bool { ffmpeg != nil }

    // Engine (built on first load so launching the app never touches the audio device)
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let varispeed = AVAudioUnitVarispeed()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private let gain = AVAudioUnitEQ(numberOfBands: 0)
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var segmentStart: Double = 0
    @ObservationIgnored private var scheduledEnd: Double = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var job: FFmpegConverter.Job?
    @ObservationIgnored private var resultPlayer: AVAudioPlayer?
    @ObservationIgnored private var loadToken = 0

    static let bitrates = [96, 128, 192, 256, 320]
    static let speedRange = 0.25...3.0
    private static let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("atfm-audio-edit")

    init() {
        let defaults = UserDefaults.standard
        format = AudioExportFormat(rawValue: defaults.string(forKey: "audioEditFormat") ?? "") ?? .mp3
        let storedBitrate = defaults.integer(forKey: "audioEditBitrate")
        bitrate = Self.bitrates.contains(storedBitrate) ? storedBitrate : 192
        location = Location(rawValue: defaults.string(forKey: "audioEditLocation") ?? "") ?? .sameFolder
        try? FileManager.default.removeItem(at: Self.tempDirectory)     // leftovers from a previous run
    }

    // MARK: Loading

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "편집할 오디오 파일을 고르세요 (동영상을 고르면 소리만 가져와요)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    static func isLoadable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                if Self.isLoadable(url) { self.load(url) } else { self.loadError = "오디오나 동영상 파일이 아니에요: \(url.lastPathComponent)" }
            }
        }
        return true
    }

    func load(_ url: URL) {
        stopAll()
        loadToken += 1
        let token = loadToken
        isLoading = true
        loadError = nil
        exportError = nil
        lastOutput = nil
        let ffmpegPath = ffmpeg?.ffmpegPath
        let previousTemp = source.flatMap { $0.playURL != $0.url ? $0.playURL : nil }
        Task.detached(priority: .userInitiated) {
            let opened = Self.open(url: url, ffmpegPath: ffmpegPath)
            await MainActor.run {
                guard token == self.loadToken else { return }
                self.isLoading = false
                if let previousTemp { try? FileManager.default.removeItem(at: previousTemp) }
                guard let opened else {
                    self.loadError = ffmpegPath == nil
                        ? "이 파일은 바로 열 수 없어요. ffmpeg가 있으면 대부분의 형식을 열 수 있어요 (brew install ffmpeg)"
                        : "이 파일에서 오디오를 읽지 못했어요"
                    return
                }
                self.finishLoading(opened)
            }
        }
    }

    private struct Opened {
        let source: Source
        let bars: [Float]
    }

    /// Opens the file with AVAudioFile, or (ogg/opus/webm/odd containers) decodes a temp WAV with ffmpeg first.
    nonisolated private static func open(url: URL, ffmpegPath: String?) -> Opened? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        var playURL = url
        var audioFile = try? AVAudioFile(forReading: url)
        if audioFile == nil || (audioFile?.length ?? 0) <= 0, let ffmpegPath {
            try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            let temp = tempDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = ["-y", "-v", "error", "-nostdin", "-i", url.path, "-vn", "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le", temp.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0, let decoded = try? AVAudioFile(forReading: temp) else {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            audioFile = decoded
            playURL = temp
        }
        guard let audioFile, audioFile.length > 0 else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        let source = Source(url: url, playURL: playURL, duration: Double(audioFile.length) / sampleRate, sampleRate: sampleRate,
                            channels: Int(audioFile.processingFormat.channelCount), fileSize: size)
        return Opened(source: source, bars: waveformBars(of: audioFile, buckets: 320))
    }

    /// Peak per bucket, normalised to the loudest bucket. Long files are sampled sparsely inside each bucket.
    nonisolated static func waveformBars(of file: AVAudioFile, buckets: Int) -> [Float] {
        let total = Int(file.length)
        guard total > 0, buckets > 0 else { return [] }
        let perBucket = max(1, total / buckets)
        let stride = max(1, perBucket / 400)
        var peaks = [Float](repeating: 0, count: buckets)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        file.framePosition = 0
        var position = 0
        while position < total {
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            var frame = 0
            while frame < frames {
                var value: Float = 0
                for channel in 0..<channels { value = max(value, abs(data[channel][frame])) }
                let bucket = min(buckets - 1, (position + frame) / perBucket)
                if value > peaks[bucket] { peaks[bucket] = value }
                frame += stride
            }
            position += frames
        }
        let top = max(peaks.max() ?? 1, 0.0001)
        return peaks.map { min(1, $0 / top) }
    }

    private func finishLoading(_ opened: Opened) {
        guard let audioFile = try? AVAudioFile(forReading: opened.source.playURL) else {
            loadError = "미리 듣기용으로 파일을 열지 못했어요"
            return
        }
        file = audioFile
        source = opened.source
        waveform = opened.bars
        settings = AudioEditSettings(start: 0, end: opened.source.duration)
        currentTime = 0
        prepareEngine(format: audioFile.processingFormat)
    }

    func close() {
        stopAll()
        loadToken += 1
        if let source, source.playURL != source.url { try? FileManager.default.removeItem(at: source.playURL) }
        source = nil
        file = nil
        waveform = []
        isLoading = false
        loadError = nil
        exportError = nil
        lastOutput = nil
        currentTime = 0
    }

    // MARK: Editing

    func setTrimStart(_ value: Double) {
        guard let source else { return }
        settings.start = min(max(0, value), max(0, settings.end - 0.1))
        _ = source
    }

    func setTrimEnd(_ value: Double) {
        guard let source else { return }
        settings.end = max(min(source.duration, value), settings.start + 0.1)
    }

    func resetTrim() {
        guard let source else { return }
        settings.start = 0
        settings.end = source.duration
        trimCommitted()
    }

    func resetEffects() {
        let start = settings.start, end = settings.end
        settings = AudioEditSettings(start: start, end: end)
    }

    /// After a handle drag ends: re-schedule so playback honours the new range.
    func trimCommitted() {
        guard isPlaying else {
            if currentTime < settings.start || currentTime > settings.end { currentTime = settings.start }
            return
        }
        startPlayback(from: min(max(currentTime, settings.start), max(settings.start, settings.end - 0.05)))
    }

    var isTrimmed: Bool {
        guard let source else { return false }
        return settings.start > 0.005 || settings.end < source.duration - 0.005
    }

    var hasEffects: Bool {
        abs(settings.speed - 1) > 0.0005 || abs(settings.gainDB) > 0.05 || settings.fadeIn > 0.01 || settings.fadeOut > 0.01 || settings.normalize || settings.reverse
    }

    var estimatedBytes: UInt64? {
        guard format.isLossy else { return nil }
        let rate = format == .ogg ? min(bitrate, 256) : bitrate
        return UInt64(max(0, settings.outputDuration) * Double(rate) * 1000 / 8)
    }

    // MARK: Live preview

    private func prepareEngine(format: AVAudioFormat) {
        let engine = self.engine ?? {
            let engine = AVAudioEngine()
            engine.attach(player)
            engine.attach(varispeed)
            engine.attach(timePitch)
            engine.attach(gain)
            self.engine = engine
            return engine
        }()
        engine.stop()
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: timePitch, format: format)
        engine.connect(timePitch, to: gain, format: format)
        engine.connect(gain, to: engine.mainMixerNode, format: format)
        applyLiveSettings()
    }

    private func applyLiveSettings() {
        let speed = Float(min(max(settings.speed, Self.speedRange.lowerBound), Self.speedRange.upperBound))
        if settings.keepPitch {
            timePitch.rate = speed
            varispeed.rate = 1
        } else {
            timePitch.rate = 1
            varispeed.rate = speed
        }
        gain.globalGain = Float(min(max(settings.gainDB, -40), 24))
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard file != nil else { return }
        stopResultPreview()
        var from = currentTime
        if from < settings.start - 0.01 || from >= settings.end - 0.05 { from = settings.start }
        startPlayback(from: from)
    }

    private func startPlayback(from position: Double) {
        guard let file, let engine else { return }
        generation += 1
        let token = generation
        player.stop()
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, position) * sampleRate)
        let frames = max(0, min(Double(file.length), settings.end * sampleRate) - Double(startFrame))
        guard frames >= 1 else { finishPlayback(); return }
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(frames), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(token) }
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            loadError = "소리 출력을 시작하지 못했어요: \(error.localizedDescription)"
            return
        }
        player.play()
        segmentStart = position
        scheduledEnd = settings.end
        currentTime = position
        isPlaying = true
        startTicker()
    }

    private func segmentFinished(_ token: Int) {
        guard token == generation, isPlaying else { return }
        if settings.end > scheduledEnd + 0.05 {          // the end handle moved outward while playing
            startPlayback(from: scheduledEnd)
        } else if loop {
            startPlayback(from: settings.start)
        } else {
            finishPlayback()
        }
    }

    private func finishPlayback() {
        generation += 1
        player.stop()
        engine?.pause()
        isPlaying = false
        currentTime = settings.start
        stopTickerIfIdle()
    }

    func pause() {
        guard isPlaying else { return }
        updateCurrentTime()
        generation += 1
        player.stop()
        engine?.pause()
        isPlaying = false
        stopTickerIfIdle()
    }

    func seek(to time: Double) {
        guard let source else { return }
        let clamped = min(max(0, time), source.duration)
        if isPlaying {
            startPlayback(from: min(max(clamped, settings.start), max(settings.start, settings.end - 0.05)))
        } else {
            currentTime = clamped
        }
    }

    private func updateCurrentTime() {
        guard isPlaying, let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return }
        let position = segmentStart + Double(time.sampleTime) / time.sampleRate
        currentTime = min(max(0, position), source?.duration ?? position)
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTickerIfIdle() {
        guard !isPlaying, resultPreview != .playing else { return }
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        if isPlaying {
            updateCurrentTime()
            if currentTime >= settings.end - 0.005 {           // trimmed shorter while playing
                if loop { startPlayback(from: settings.start) } else { finishPlayback() }
            } else if currentTime < settings.start - 0.05 {
                startPlayback(from: settings.start)
            }
        }
        if resultPreview == .playing, resultPlayer?.isPlaying != true {
            resultPreview = .idle
            resultPlayer = nil
            stopTickerIfIdle()
        }
    }

    /// Development: play silently and report whether the playhead advances at the expected rate.
    func debugPlayMuted(seconds: Double, report: @escaping (String) -> Void) {
        guard let engine else { report("no engine"); return }
        engine.mainMixerNode.outputVolume = 0
        let from = settings.start
        seek(to: from)
        play()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                report(String(format: "playing=%@ advanced %.2f s of source in %.1f s (speed %.2f, keepPitch=%@)",
                              self.isPlaying ? "yes" : "no", self.currentTime - from, seconds, self.settings.speed, self.settings.keepPitch ? "yes" : "no"))
                self.pause()
                engine.mainMixerNode.outputVolume = 1
            }
        }
    }

    /// The bubble closed or another tab is showing: stop making sound.
    func setActive(_ active: Bool) {
        guard !active else { return }
        pause()
        stopResultPreview()
    }

    private func stopAll() {
        if isPlaying { pause() }
        stopResultPreview()
        job?.cancel()
        engine?.stop()
    }

    func shutdown() {
        stopAll()
        try? FileManager.default.removeItem(at: Self.tempDirectory)
    }

    // MARK: Export

    private func outputURL(for source: Source) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let parent = source.url.deletingLastPathComponent()
        let folder = location == .sameFolder && FileManager.default.isWritableFile(atPath: parent.path) ? parent : downloads
        let base = source.url.deletingPathExtension().lastPathComponent + "-편집"
        var candidate = folder.appendingPathComponent(base + "." + format.ext)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(number).\(format.ext)")
            number += 1
        }
        return candidate
    }

    var isExporting: Bool { exportProgress != nil }

    func export() {
        guard let source, let ffmpeg, !isExporting else { return }
        guard settings.selectedDuration >= 0.1 else { exportError = "선택한 구간이 너무 짧아요"; return }
        let output = outputURL(for: source)
        let arguments = settings.arguments(input: source.url, output: output, format: format, bitrate: bitrate,
                                           sampleRate: Int(source.sampleRate), fullDuration: source.duration)
        exportProgress = 0
        exportError = nil
        lastOutput = nil
        let job = FFmpegConverter.Job()
        self.job = job
        let duration = settings.outputDuration
        Task {
            do {
                try await ffmpeg.run(arguments: arguments, duration: duration, job: job) { progress in
                    Task { @MainActor in if self.exportProgress != nil { self.exportProgress = progress } }
                }
                self.lastOutput = output
                self.notify?("오디오 저장됨", output.lastPathComponent)
            } catch {
                try? FileManager.default.removeItem(at: output)
                if case ConvertError.cancelled = error { self.exportError = nil } else { self.exportError = error.localizedDescription }
            }
            self.exportProgress = nil
            self.job = nil
        }
    }

    func cancelExport() { job?.cancel() }

    func revealOutput() {
        guard let lastOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutput])
    }

    // MARK: Result preview (exactly what export would produce: fades, loudness, reverse included)

    func toggleResultPreview() {
        if resultPreview != .idle { stopResultPreview(); return }
        guard let source, let ffmpeg else { return }
        pause()
        try? FileManager.default.createDirectory(at: Self.tempDirectory, withIntermediateDirectories: true)
        let output = Self.tempDirectory.appendingPathComponent("preview-\(UUID().uuidString).wav")
        let arguments = settings.arguments(input: source.url, output: output, format: .wav, bitrate: 0,
                                           sampleRate: Int(source.sampleRate), fullDuration: source.duration)
        resultPreview = .rendering(0)
        let job = FFmpegConverter.Job()
        self.job = job
        let duration = settings.outputDuration
        Task {
            do {
                try await ffmpeg.run(arguments: arguments, duration: duration, job: job) { progress in
                    Task { @MainActor in if case .rendering = self.resultPreview { self.resultPreview = .rendering(progress) } }
                }
                guard case .rendering = self.resultPreview else { try? FileManager.default.removeItem(at: output); return }
                let player = try AVAudioPlayer(contentsOf: output)
                self.resultPlayer = player
                player.play()
                self.resultPreview = .playing
                self.startTicker()
            } catch {
                if case ConvertError.cancelled = error {} else { self.exportError = "미리 듣기 실패: \(error.localizedDescription)" }
                self.resultPreview = .idle
            }
            self.job = nil
        }
    }

    func stopResultPreview() {
        if case .rendering = resultPreview { job?.cancel() }
        resultPlayer?.stop()
        resultPlayer = nil
        resultPreview = .idle
        stopTickerIfIdle()
    }

    // MARK: Time text

    /// "1:02.3" (or "1:02:03.4" past an hour).
    static func timeText(_ seconds: Double) -> String {
        let value = max(0, seconds)
        let whole = Int(value)
        let tenths = Int((value - Double(whole)) * 10 + 0.0001)
        if whole >= 3600 { return String(format: "%d:%02d:%02d.%d", whole / 3600, (whole % 3600) / 60, whole % 60, tenths) }
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }

    /// Accepts "83.4", "1:23.4" or "1:02:03".
    static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}
