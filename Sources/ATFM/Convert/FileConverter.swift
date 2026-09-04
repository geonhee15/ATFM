import AppKit
import Observation
import QuickLookThumbnailing

struct ConvertItem: Identifiable {
    enum Status: Equatable {
        case waiting
        case running(Double)
        case done(URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let url: URL
    let kind: MediaKind
    let sizeBytes: Int64
    var status: Status = .waiting

    var name: String { url.lastPathComponent }
    var isWaiting: Bool { if case .waiting = status { return true } else { return false } }
    var isRunning: Bool { if case .running = status { return true } else { return false } }
}

enum OutputLocation: Equatable {
    case sameFolder
    case downloads
    case custom(URL)

    var title: String {
        switch self {
        case .sameFolder: return "원본과 같은 폴더"
        case .downloads: return "다운로드 폴더"
        case .custom(let url): return url.lastPathComponent
        }
    }
}

/// Conversion queue for the 파일 변환 tab. Images go through ImageIO; video/audio through ffmpeg
/// when installed, otherwise AVFoundation's export presets.
@MainActor
@Observable
final class FileConverter {
    private(set) var items: [ConvertItem] = []
    private(set) var isRunning = false
    private(set) var thumbnails: [UUID: NSImage] = [:]
    var imageTarget: OutputFormat
    var videoTarget: OutputFormat
    var audioTarget: OutputFormat
    var imageQuality: Double = 0.85
    var imageMaxSize: ImageMaxSize = .original
    var videoResolution: VideoResolution = .original
    var videoQuality: VideoQuality = .high
    var audioBitrate: Int = 192
    var outputLocation: OutputLocation = .sameFolder

    let ffmpeg: FFmpegConverter?
    let engineName: String
    let imageFormats: [OutputFormat]
    let videoFormats: [OutputFormat]
    let audioFormats: [OutputFormat]
    static let bitrates = [128, 192, 256, 320]

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var ffmpegJob: FFmpegConverter.Job?
    @ObservationIgnored private var avJob: AVFoundationConverter.Job?

    init() {
        let ffmpeg = FFmpegConverter.locate()
        self.ffmpeg = ffmpeg
        engineName = ffmpeg?.versionString ?? "내장 엔진"
        imageFormats = OutputFormat.image
        videoFormats = ffmpeg != nil ? OutputFormat.videoFFmpeg : OutputFormat.videoBuiltin
        audioFormats = ffmpeg != nil ? OutputFormat.audioFFmpeg : OutputFormat.audioBuiltin
        imageTarget = imageFormats.first { $0.id == "png" } ?? imageFormats[0]
        videoTarget = videoFormats[0]
        audioTarget = audioFormats[0]
    }

    /// Video files may also be turned into audio-only files.
    var videoTargets: [OutputFormat] { videoFormats + audioFormats }

    var pendingCount: Int { items.filter(\.isWaiting).count }
    var doneCount: Int { items.filter { if case .done = $0.status { return true } else { return false } }.count }

    func items(of kind: MediaKind) -> [ConvertItem] { items.filter { $0.kind == kind } }

    func target(for kind: MediaKind) -> OutputFormat {
        switch kind {
        case .image: return imageTarget
        case .video: return videoTarget
        case .audio: return audioTarget
        }
    }

    // MARK: Queue management

    func add(urls: [URL]) {
        for url in urls {
            guard let kind = MediaKind.detect(url), !items.contains(where: { $0.url == url }) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let item = ConvertItem(url: url, kind: kind, sizeBytes: size)
            items.append(item)
            loadThumbnail(for: item)
        }
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isRunning else { return }
        items.removeAll { $0.id == id }
        thumbnails[id] = nil
    }

    func clear() {
        items.removeAll { !$0.isRunning }
        thumbnails = thumbnails.filter { key, _ in items.contains { $0.id == key } }
    }

    func resetFinished() {
        for index in items.indices where !items[index].isRunning {
            items[index].status = .waiting
        }
    }

    private func loadThumbnail(for item: ConvertItem) {
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 44, height: 44), scale: 2, representationTypes: .thumbnail)
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.thumbnails[id] = image }
            }
        }
    }

    // MARK: Panels

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "변환할 이미지 · 영상 · 오디오 파일을 고르세요"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.add(urls: panel.urls)
            }
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "변환한 파일을 저장할 폴더"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.outputLocation = .custom(url)
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Running

    func run() {
        guard !isRunning, pendingCount > 0 else { return }
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let next = items.first(where: \.isWaiting) {
                await convert(itemID: next.id)
            }
            isRunning = false
        }
    }

    func cancel() {
        runTask?.cancel()
        ffmpegJob?.cancel()
        avJob?.cancel()
    }

    private func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func setStatus(_ id: UUID, _ status: ConvertItem.Status) {
        guard let index = index(of: id) else { return }
        items[index].status = status
    }

    private func convert(itemID: UUID) async {
        guard let index = index(of: itemID) else { return }
        let item = items[index]
        let format = target(for: item.kind)
        let output = outputURL(for: item, format: format)
        items[index].status = .running(0)
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.setStatus(itemID, .running(value)) }
        }
        do {
            if item.kind == .image {
                let quality = imageQuality
                let maxSize = imageMaxSize.rawValue
                try await Task.detached(priority: .userInitiated) {
                    try ImageConverter.convert(input: item.url, output: output, format: format, quality: quality, maxPixelSize: maxSize)
                }.value
            } else if let ffmpeg {
                let job = FFmpegConverter.Job()
                ffmpegJob = job
                let duration = await Task.detached { ffmpeg.duration(of: item.url) }.value
                let options = FFmpegConverter.VideoOptions(resolution: videoResolution, quality: videoQuality, audioBitrate: audioBitrate)
                let arguments = ffmpeg.arguments(input: item.url, output: output, format: format, video: options, audioBitrate: audioBitrate)
                try await ffmpeg.run(arguments: arguments, duration: duration, job: job, progress: progress)
                ffmpegJob = nil
            } else {
                let job = AVFoundationConverter.Job()
                avJob = job
                try await AVFoundationConverter.convert(input: item.url, output: output, format: format,
                                                        resolution: videoResolution, job: job, progress: progress)
                avJob = nil
            }
            setStatus(itemID, .done(output))
        } catch {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled || (error as? ConvertError) == .cancelled {
                setStatus(itemID, .cancelled)
            } else {
                setStatus(itemID, .failed(error.localizedDescription))
            }
        }
    }

    func outputURL(for item: ConvertItem, format: OutputFormat) -> URL {
        let sourceDir = item.url.deletingLastPathComponent()
        let dir: URL
        switch outputLocation {
        case .sameFolder: dir = sourceDir
        case .downloads: dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .custom(let url): dir = url
        }
        var base = item.url.deletingPathExtension().lastPathComponent
        let sourceExt = item.url.pathExtension.lowercased().replacingOccurrences(of: "jpeg", with: "jpg")
        let targetExt = format.ext.lowercased().replacingOccurrences(of: "jpeg", with: "jpg")
        if sourceExt == targetExt && dir == sourceDir { base += "-변환" }
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(format.ext)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(counter)").appendingPathExtension(format.ext)
            counter += 1
        }
        return candidate
    }
}

extension ConvertError: Equatable {
    static func == (lhs: ConvertError, rhs: ConvertError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled): return true
        case (.unsupported(let a), .unsupported(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}
