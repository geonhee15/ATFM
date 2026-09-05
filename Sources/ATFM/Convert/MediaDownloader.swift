import AppKit
import Observation

enum DownloadQuality: String, CaseIterable, Identifiable {
    case best, bestCompatible, p1080, p720, audioMP3
    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "최고 화질 (원본 코덱)"
        case .bestCompatible: return "최고 화질 (H.264 호환)"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .audioMP3: return "오디오만 (MP3)"
        }
    }

    var subtitle: String {
        switch self {
        case .best: return "4K·VP9/AV1도 그대로. 일부 플레이어에서 안 열릴 수 있음"
        case .bestCompatible: return "H.264로 받을 수 있는 최고 해상도. QuickTime·아이폰 OK"
        case .p1080: return "1080p 이하 최고"
        case .p720: return "720p 이하 최고"
        case .audioMP3: return "영상 없이 소리만 MP3로"
        }
    }

    /// yt-dlp format selection.
    var arguments: [String] {
        switch self {
        // Video-only DASH streams (`bv`) merged with audio: YouTube's progressive URLs (`b`)
        // 403 on the default player client here, while the DASH streams download fine.
        case .best:
            return ["-f", "bv+ba/b", "--merge-output-format", "mp4"]
        case .bestCompatible:
            return ["-f", "bv[vcodec^=avc1]+ba[ext=m4a]/bv[vcodec^=avc1]+ba/bv+ba/b", "--merge-output-format", "mp4"]
        case .p1080:
            return ["-f", "bv[height<=1080]+ba/bv+ba/b", "--merge-output-format", "mp4"]
        case .p720:
            return ["-f", "bv[height<=720]+ba/bv+ba/b", "--merge-output-format", "mp4"]
        case .audioMP3:
            return ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        }
    }
}

struct DownloadRecord: Identifiable {
    let id = UUID()
    let title: String
    let fileURL: URL
    let finishedAt: Date
}

/// Downloads videos/audio from YouTube (and any site yt-dlp supports) with progress, using the
/// Homebrew `yt-dlp` binary and the same ffmpeg the converter uses for merging.
@MainActor
@Observable
final class MediaDownloader {
    enum Phase: Equatable {
        case idle
        case fetchingInfo
        case downloading
        case merging
        case done
        case failed(String)
    }

    var url = ""
    var quality: DownloadQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey) }
    }
    private(set) var outputDirectory: URL
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var speed = ""
    private(set) var eta = ""
    private(set) var sizeText = ""
    private(set) var title = ""
    private(set) var duration = ""
    private(set) var resolution = ""
    private(set) var lastFile: URL?
    private(set) var history: [DownloadRecord] = []

    let ytdlpPath: String?
    private let ffmpegDirectory: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var stderrData = Data()
    @ObservationIgnored private var printedPath: String?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var lastTarget = ""
    private static let qualityKey = "downloadQuality"
    private static let directoryKey = "downloadDirectory"
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    var isBusy: Bool { phase == .fetchingInfo || phase == .downloading || phase == .merging }
    var isAvailable: Bool { ytdlpPath != nil }

    init() {
        ytdlpPath = Self.searchPaths.map { $0 + "/yt-dlp" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        ffmpegDirectory = Self.searchPaths.first { FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") }
        quality = DownloadQuality(rawValue: UserDefaults.standard.string(forKey: Self.qualityKey) ?? "") ?? .bestCompatible
        if let stored = UserDefaults.standard.string(forKey: Self.directoryKey), FileManager.default.fileExists(atPath: stored) {
            outputDirectory = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
    }

    // MARK: Inputs

    static func isYouTube(_ text: String) -> Bool {
        guard let host = URL(string: text)?.host?.lowercased() else { return false }
        return host.contains("youtube.com") || host.contains("youtu.be")
    }

    static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
        return (scheme == "http" || scheme == "https") && host.contains(".")
    }

    /// Fills the field from the clipboard when it holds a link and the field is empty.
    func pasteIfLink() {
        guard url.isEmpty, let text = NSPasteboard.general.string(forType: .string), Self.looksLikeURL(text) else { return }
        url = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "다운로드한 파일을 저장할 폴더"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let directory = panel.url else { return }
                self?.outputDirectory = directory
                UserDefaults.standard.set(directory.path, forKey: Self.directoryKey)
            }
        }
    }

    func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // MARK: Download

    func start() {
        guard !isBusy else { return }
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeURL(target) else {
            phase = .failed("YouTube 등 영상 링크를 붙여넣어 주세요")
            return
        }
        attempt = 0
        launch(target: target, extraArguments: Self.isYouTube(target) ? Self.youtubeAttempts[0] : [])
    }

    /// YouTube (2026): yt-dlp's default player client lists every DASH stream, but its URLs answer
    /// 403 a few chunks into the download ("SABR-only" experiment, yt-dlp issue 12482), while the
    /// embedded-player client streams the same formats fine without a PO token. Try that first;
    /// if the video can't be embedded, fall back to the defaults, then to the mobile-web client
    /// whose (progressive, lower-quality) URLs always work.
    private static let youtubeAttempts: [[String]] = [
        ["--extractor-args", "youtube:player_client=web_embedded"],
        [],
        ["--extractor-args", "youtube:player_client=mweb,web"],
    ]

    private func launch(target: String, extraArguments: [String]) {
        guard let ytdlpPath else { return }
        cancelled = false
        title = ""; duration = ""; resolution = ""
        progress = 0; speed = ""; eta = ""; sizeText = ""
        lastFile = nil
        printedPath = nil
        buffer = Data()
        stderrData = Data()
        phase = .fetchingInfo

        var arguments = ["--no-playlist", "--newline", "--progress", "--no-simulate", "--no-warnings",
                         "--print", "before_dl:ATFM_TITLE=%(title)s",
                         "--print", "before_dl:ATFM_DURATION=%(duration_string)s",
                         "--print", "before_dl:ATFM_RES=%(resolution)s",
                         "--print", "after_move:ATFM_FILE=%(filepath)s",
                         "-N", "4",
                         "-o", outputDirectory.appendingPathComponent("%(title)s [%(id)s].%(ext)s").path]
        if let ffmpegDirectory { arguments += ["--ffmpeg-location", ffmpegDirectory] }
        arguments += extraArguments
        arguments += quality.arguments
        arguments.append(target)
        lastTarget = target

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlpPath)
        process.arguments = arguments
        process.currentDirectoryURL = outputDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (Self.searchPaths + ["/usr/bin", "/bin"]).joined(separator: ":")
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stderrData.append(data) } }
        }
        process.terminationHandler = { [weak self] finished in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let trailing = out.fileHandleForReading.readDataToEndOfFile()
            let trailingErr = err.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !trailing.isEmpty { self.consume(trailing) }
                    self.stderrData.append(trailingErr)
                    self.finish(status: finished.terminationStatus, reason: finished.terminationReason)
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            phase = .failed("yt-dlp를 실행하지 못했어요: \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        cancelled = true
        process.terminate()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { handle(line: line) }
        }
    }

    private static let progressRegex = try! NSRegularExpression(
        pattern: #"\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+\s*\w+)(?:\s+at\s+([\d.]+\s*\w+/s|Unknown \w+))?(?:\s+ETA\s+([\d:]+|Unknown))?"#)

    private func handle(line: String) {
        if line.hasPrefix("ATFM_TITLE=") { title = String(line.dropFirst("ATFM_TITLE=".count)); return }
        if line.hasPrefix("ATFM_DURATION=") { duration = String(line.dropFirst("ATFM_DURATION=".count)); return }
        if line.hasPrefix("ATFM_RES=") { resolution = String(line.dropFirst("ATFM_RES=".count)); return }
        if line.hasPrefix("ATFM_FILE=") { printedPath = String(line.dropFirst("ATFM_FILE=".count)); return }
        if line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[VideoConvertor]") {
            phase = .merging
            return
        }
        let ns = line as NSString
        if let match = Self.progressRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            phase = .downloading
            progress = (Double(ns.substring(with: match.range(at: 1))) ?? 0) / 100
            sizeText = ns.substring(with: match.range(at: 2))
            speed = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : ""
            eta = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : ""
        } else if line.hasPrefix("[download]"), phase == .fetchingInfo {
            phase = .downloading
        }
    }

    private func finish(status: Int32, reason: Process.TerminationReason) {
        process = nil
        if cancelled {
            phase = .failed("중단했어요")
            return
        }
        if status == 0, let printedPath, FileManager.default.fileExists(atPath: printedPath) {
            let file = URL(fileURLWithPath: printedPath)
            lastFile = file
            progress = 1
            phase = .done
            history.insert(DownloadRecord(title: title.isEmpty ? file.deletingPathExtension().lastPathComponent : title,
                                          fileURL: file, finishedAt: Date()), at: 0)
            if history.count > 10 { history.removeLast(history.count - 10) }
            return
        }
        let stderr = String(decoding: stderrData, as: UTF8.self)
        if Self.isYouTube(lastTarget), attempt + 1 < Self.youtubeAttempts.count {
            attempt += 1
            launch(target: lastTarget, extraArguments: Self.youtubeAttempts[attempt])
            return
        }
        let errorLine = stderr.split(separator: "\n").last { $0.contains("ERROR") } ?? stderr.split(separator: "\n").last
        let message = errorLine.map { String($0).replacingOccurrences(of: "ERROR: ", with: "") } ?? "yt-dlp 종료 코드 \(status)"
        phase = .failed(message.isEmpty ? "다운로드에 실패했어요" : String(message.prefix(200)))
    }
}
