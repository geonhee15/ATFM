import AppKit
import AVFoundation
import Observation
import SwiftUI

// MARK: - Model

struct RGBA: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent); g = Double(ns.greenComponent); b = Double(ns.blueComponent); a = Double(ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var isDark: Bool { 0.299 * r + 0.587 * g + 0.114 * b < 0.5 }

    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0.1, g: 0.1, b: 0.12)
    static let ink = RGBA(r: 0.16, g: 0.18, b: 0.22)
    static let accent = RGBA(r: 0.24, g: 0.49, b: 0.95)
    static let palette: [RGBA] = [
        RGBA(r: 0.24, g: 0.49, b: 0.95), RGBA(r: 0.95, g: 0.36, b: 0.33), RGBA(r: 0.99, g: 0.72, b: 0.22), RGBA(r: 0.24, g: 0.72, b: 0.48),
        RGBA(r: 0.62, g: 0.42, b: 0.93), RGBA(r: 0.95, g: 0.55, b: 0.72), RGBA(r: 0.20, g: 0.68, b: 0.80), RGBA(r: 0.55, g: 0.55, b: 0.58),
    ]
}

enum AspectPreset: String, Codable, CaseIterable, Identifiable {
    case r16x9 = "16:9", r9x16 = "9:16", r1x1 = "1:1", r4x3 = "4:3", r3x4 = "3:4", r21x9 = "21:9", r4x5 = "4:5"
    var id: String { rawValue }
    var ratio: CGFloat {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? CGFloat(parts[0] / parts[1]) : 16.0 / 9.0
    }
    var subtitle: String {
        switch self {
        case .r16x9: return "유튜브 · 가로"
        case .r9x16: return "쇼츠 · 릴스"
        case .r1x1: return "정사각"
        case .r4x3: return "클래식"
        case .r3x4: return "세로 4:3"
        case .r21x9: return "시네마"
        case .r4x5: return "인스타 피드"
        }
    }
}

enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case rect, roundedRect, ellipse, triangle, arrow, star, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rect: return "사각형"
        case .roundedRect: return "둥근 사각형"
        case .ellipse: return "원"
        case .triangle: return "삼각형"
        case .arrow: return "화살표"
        case .star: return "별"
        case .text: return "텍스트"
        }
    }
    var symbol: String {
        switch self {
        case .rect: return "square"
        case .roundedRect: return "square.on.square"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .arrow: return "arrow.right"
        case .star: return "star"
        case .text: return "textformat"
        }
    }
}

/// One object on a scene. Position/size are fractions of the canvas (x, y = centre; w, h = size).
struct SceneItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ItemKind
    var x: Double = 0.5
    var y: Double = 0.5
    var w: Double = 0.3
    var h: Double = 0.3
    var color: RGBA = .accent
    var filled = true
    var text = ""
    var fontSize: Double = 0.09      // fraction of the canvas height
}

struct Stroke: Codable, Equatable {
    var points: [Double]             // x0, y0, x1, y1… as fractions of the canvas
    var color: RGBA
    var width: Double                // fraction of the canvas height
}

struct StoryScene: Identifiable, Codable, Equatable {
    var id = UUID()
    var aspect: AspectPreset = .r16x9
    var background: RGBA = .white
    var items: [SceneItem] = []
    var strokes: [Stroke] = []
    var note = ""                    // what happens / dialogue
}

struct MusicTrack: Codable, Equatable {
    var path: String
    var duration: Double
    var cuts: [Double]               // scene boundaries (seconds), count = scenes − 1
    var name: String { (path as NSString).lastPathComponent }
}

struct Storyboard: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var scenes: [StoryScene]
    var music: MusicTrack?
    var createdAt = Date()
    var updatedAt = Date()

    /// Time range of each scene along the music (nil without music).
    func segment(of index: Int) -> ClosedRange<Double>? {
        guard let music, index >= 0, index < scenes.count else { return nil }
        let cuts = music.cuts
        let start = index == 0 ? 0 : (index - 1 < cuts.count ? cuts[index - 1] : 0)
        let end = index == scenes.count - 1 ? music.duration : (index < cuts.count ? cuts[index] : music.duration)
        return min(start, end)...max(start, end)
    }
}

// MARK: - Store

/// 스토리보드: scenes with shapes, text and sketches, plus a music track cut into per-scene ranges.
/// Autosaved to storyboards.json next to the other stores.
@MainActor
@Observable
final class StoryboardStore {
    enum Tool: String, CaseIterable, Identifiable {
        case select, pen, text
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: return "선택"
            case .pen: return "펜"
            case .text: return "텍스트"
            }
        }
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .pen: return "pencil.tip"
            case .text: return "textformat"
            }
        }
    }

    private(set) var boards: [Storyboard] = []
    var selectedBoardID: UUID? {
        didSet { UserDefaults.standard.set(selectedBoardID?.uuidString, forKey: Self.selectedKey); selectedSceneID = board?.scenes.first?.id; selectedItemID = nil; stopPlayback(); loadMusic() }
    }
    var selectedSceneID: UUID? {
        didSet { if oldValue != selectedSceneID { selectedItemID = nil } }
    }
    var selectedItemID: UUID?
    var tool: Tool = .select
    var penColor: RGBA = .ink
    var penWidth: Double = 0.008

    // Playback
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var waveform: [Float] = []
    private(set) var musicError: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playTimer: Timer?
    @ObservationIgnored private var waveformPath: String?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var windowController: StoryboardWindowController?
    private static let selectedKey = "storyboardSelected"

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("storyboards.json")
        load()
        if boards.isEmpty { boards = [Self.blankBoard()] ; scheduleSave() }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey), let id = UUID(uuidString: raw), boards.contains(where: { $0.id == id }) {
            selectedBoardID = id
        } else {
            selectedBoardID = boards.first?.id
        }
    }

    static func blankBoard(title: String = "새 스토리보드") -> Storyboard {
        Storyboard(title: title, scenes: [StoryScene(), StoryScene(), StoryScene()], music: nil)
    }

    // MARK: Boards

    var board: Storyboard? { boards.first { $0.id == selectedBoardID } }
    var boardIndex: Int? { boards.firstIndex { $0.id == selectedBoardID } }

    func addBoard() {
        let board = Self.blankBoard(title: "스토리보드 \(boards.count + 1)")
        boards.insert(board, at: 0)
        selectedBoardID = board.id
        scheduleSave()
    }

    func rename(_ title: String) {
        mutate { $0.title = title.isEmpty ? "스토리보드" : title }
    }

    func deleteBoard() {
        guard let index = boardIndex else { return }
        boards.remove(at: index)
        if boards.isEmpty { boards = [Self.blankBoard()] }
        selectedBoardID = boards[min(index, boards.count - 1)].id
        scheduleSave()
    }

    private func mutate(_ change: (inout Storyboard) -> Void) {
        guard let index = boardIndex else { return }
        change(&boards[index])
        boards[index].updatedAt = Date()
        scheduleSave()
    }

    // MARK: Scenes

    var scenes: [StoryScene] { board?.scenes ?? [] }
    var scene: StoryScene? { scenes.first { $0.id == selectedSceneID } ?? scenes.first }
    var sceneIndex: Int? { scenes.firstIndex { $0.id == (scene?.id) } }

    /// The scene the canvas shows: the one at the playhead while playing, otherwise the selection.
    var displayedScene: StoryScene? {
        if isPlaying, let index = playbackSceneIndex, index < scenes.count { return scenes[index] }
        return scene
    }

    func sceneTitle(_ index: Int) -> String { "Scene \(index + 1)" }

    func addScene(after: Bool = true) {
        var new = StoryScene()
        if let current = scene { new.aspect = current.aspect; new.background = current.background }
        mutate { board in
            let at = (board.scenes.firstIndex { $0.id == self.selectedSceneID }).map { $0 + 1 } ?? board.scenes.count
            board.scenes.insert(new, at: at)
            let redistributed = Self.redistribute(board.music, count: board.scenes.count); board.music?.cuts = redistributed
        }
        selectedSceneID = new.id
    }

    func duplicateScene(_ id: UUID) {
        mutate { board in
            guard let index = board.scenes.firstIndex(where: { $0.id == id }) else { return }
            var copy = board.scenes[index]
            copy.id = UUID()
            copy.items = copy.items.map { var item = $0; item.id = UUID(); return item }
            board.scenes.insert(copy, at: index + 1)
            let redistributed = Self.redistribute(board.music, count: board.scenes.count); board.music?.cuts = redistributed
            self.selectedSceneID = copy.id
        }
    }

    func deleteScene(_ id: UUID) {
        mutate { board in
            guard board.scenes.count > 1, let index = board.scenes.firstIndex(where: { $0.id == id }) else { return }
            board.scenes.remove(at: index)
            let redistributed = Self.redistribute(board.music, count: board.scenes.count); board.music?.cuts = redistributed
            if self.selectedSceneID == id { self.selectedSceneID = board.scenes[min(index, board.scenes.count - 1)].id }
        }
    }

    func moveScene(_ id: UUID, by offset: Int) {
        mutate { board in
            guard let index = board.scenes.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard target >= 0, target < board.scenes.count else { return }
            board.scenes.swapAt(index, target)
        }
    }

    func updateScene(_ change: (inout StoryScene) -> Void) {
        guard let id = scene?.id else { return }
        mutate { board in
            guard let index = board.scenes.firstIndex(where: { $0.id == id }) else { return }
            change(&board.scenes[index])
        }
    }

    // MARK: Items & strokes

    var selectedItem: SceneItem? { scene?.items.first { $0.id == selectedItemID } }

    @discardableResult
    func addItem(_ kind: ItemKind, at point: CGPoint? = nil) -> SceneItem {
        var item = SceneItem(kind: kind)
        let ratio = Double(scene?.aspect.ratio ?? 16 / 9)
        switch kind {
        case .text:
            item.text = "텍스트"; item.w = 0.5; item.h = 0.16; item.color = (scene?.background.isDark ?? false) ? .white : .ink
        case .arrow:
            item.w = 0.3; item.h = 0.3 * ratio * 0.5
        case .ellipse, .star:
            item.w = 0.22; item.h = 0.22 * ratio
        default:
            item.w = 0.28; item.h = 0.28 * ratio * 0.75
        }
        item.color = kind == .text ? item.color : RGBA.palette[(scene?.items.count ?? 0) % RGBA.palette.count]
        if let point { item.x = Double(point.x); item.y = Double(point.y) }
        updateScene { $0.items.append(item) }
        selectedItemID = item.id
        return item
    }

    func updateItem(_ id: UUID, _ change: (inout SceneItem) -> Void) {
        updateScene { scene in
            guard let index = scene.items.firstIndex(where: { $0.id == id }) else { return }
            change(&scene.items[index])
        }
    }

    func deleteItem(_ id: UUID) {
        updateScene { $0.items.removeAll { $0.id == id } }
        if selectedItemID == id { selectedItemID = nil }
    }

    func bringToFront(_ id: UUID) {
        updateScene { scene in
            guard let index = scene.items.firstIndex(where: { $0.id == id }) else { return }
            let item = scene.items.remove(at: index)
            scene.items.append(item)
        }
    }

    func addStroke(_ stroke: Stroke) {
        guard stroke.points.count >= 4 else { return }
        updateScene { $0.strokes.append(stroke) }
    }

    func undoStroke() { updateScene { _ = $0.strokes.popLast() } }
    func clearStrokes() { updateScene { $0.strokes.removeAll() } }
    func clearScene() { updateScene { $0.strokes.removeAll(); $0.items.removeAll() }; selectedItemID = nil }

    // MARK: Music

    var music: MusicTrack? { board?.music }

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "배경음악으로 쓸 오디오 파일을 고르세요"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setMusic(path: url.path)
    }

    func setMusic(path: String) {
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            musicError = "이 파일은 재생할 수 없어요"
            return
        }
        musicError = nil
        let duration = player.duration
        mutate { board in
            let track = MusicTrack(path: path, duration: duration, cuts: [])
            board.music = track
            let redistributed = Self.redistribute(board.music, count: board.scenes.count); board.music?.cuts = redistributed
        }
        loadMusic()
    }

    func removeMusic() {
        stopPlayback()
        mutate { $0.music = nil }
        player = nil
        waveform = []
        waveformPath = nil
    }

    /// Evenly spaced boundaries for `count` scenes (keeps existing ones when the count matches).
    static func redistribute(_ music: MusicTrack?, count: Int) -> [Double] {
        guard let music, count > 1 else { return [] }
        if music.cuts.count == count - 1 { return music.cuts }
        return (1..<count).map { music.duration * Double($0) / Double(count) }
    }

    func distributeEvenly() {
        mutate { board in
            guard let music = board.music else { return }
            board.music?.cuts = (1..<board.scenes.count).map { music.duration * Double($0) / Double(board.scenes.count) }
        }
    }

    /// Moves boundary `index` (between scene index and index+1), keeping at least 0.5 s per scene.
    func setCut(_ index: Int, time: Double) {
        mutate { board in
            guard var music = board.music, index >= 0, index < music.cuts.count else { return }
            let lower = (index == 0 ? 0 : music.cuts[index - 1]) + 0.5
            let upper = (index == music.cuts.count - 1 ? music.duration : music.cuts[index + 1]) - 0.5
            guard lower <= upper else { return }
            music.cuts[index] = min(max(time, lower), upper)
            board.music = music
        }
    }

    private func loadMusic() {
        stopPlayback()
        player = nil
        guard let music else { waveform = []; return }
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: music.path))
        player?.prepareToPlay()
        if player == nil { musicError = "음악 파일을 찾을 수 없어요: \(music.name)" } else { musicError = nil }
        if waveformPath != music.path {
            waveformPath = music.path
            waveform = []
            waveformTask?.cancel()
            let path = music.path
            waveformTask = Task.detached(priority: .utility) { [weak self] in
                let bars = Self.computeWaveform(path: path, buckets: 240)
                await MainActor.run { guard let self, self.waveformPath == path else { return }; self.waveform = bars }
            }
        }
    }

    nonisolated private static func computeWaveform(path: String, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return [] }
        let total = Int(file.length)
        guard total > 0 else { return [] }
        let perBucket = max(1, total / buckets)
        var sums = [Float](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        var position = 0
        while position < total {
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(buffer.format.channelCount)
            for frame in 0..<Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0..<channels { value = max(value, abs(data[channel][frame])) }
                let bucket = min(buckets - 1, (position + frame) / perBucket)
                sums[bucket] += value
                counts[bucket] += 1
            }
            position += Int(buffer.frameLength)
        }
        let averages = zip(sums, counts).map { $1 > 0 ? $0 / Float($1) : 0 }
        let peak = max(averages.max() ?? 1, 0.0001)
        return averages.map { min(1, $0 / peak) }
    }

    // MARK: Playback

    var playbackSceneIndex: Int? {
        guard let board, board.music != nil else { return nil }
        for index in board.scenes.indices {
            if let range = board.segment(of: index), range.contains(currentTime) { return index }
        }
        return board.scenes.isEmpty ? nil : board.scenes.count - 1
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if currentTime >= player.duration - 0.05 { player.currentTime = 0; currentTime = 0 }
        player.play()
        isPlaying = true
        playTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPlayback() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playTimer = timer
    }

    func pause() {
        player?.pause()
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
    }

    func stopPlayback() {
        pause()
        player?.currentTime = 0
        currentTime = 0
    }

    func seek(to time: Double) {
        guard let player else { return }
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Jumps to the start of a scene's range.
    func seek(toScene index: Int) {
        guard let range = board?.segment(of: index) else { return }
        seek(to: range.lowerBound)
    }

    private func tickPlayback() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying { pause(); currentTime = player.duration }
    }

    // MARK: Window

    func openWindow() {
        if windowController == nil { windowController = StoryboardWindowController(store: self) }
        windowController?.show()
    }

    // MARK: Persistence

    func flush() {
        saveTask?.cancel()
        Self.write(boards, to: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        boards = (try? decoder.decode([Storyboard].self, from: data)) ?? []
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = boards
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: url)
        }
    }

    nonisolated private static func write(_ snapshot: [Storyboard], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Sample (screenshots / development)

    func seedSample(musicPath: String?) {
        var board = Storyboard(title: "브이로그 인트로", scenes: [])
        var s1 = StoryScene(aspect: .r16x9, background: RGBA(r: 0.96, g: 0.93, b: 0.86))
        s1.items = [
            SceneItem(kind: .ellipse, x: 0.78, y: 0.3, w: 0.16, h: 0.28, color: RGBA(r: 0.99, g: 0.72, b: 0.22)),
            SceneItem(kind: .rect, x: 0.5, y: 0.82, w: 1.0, h: 0.36, color: RGBA(r: 0.24, g: 0.72, b: 0.48)),
            SceneItem(kind: .text, x: 0.32, y: 0.4, w: 0.5, h: 0.2, color: .ink, text: "주말 아침, 카페 가는 길", fontSize: 0.1),
        ]
        s1.strokes = [Stroke(points: [0.1, 0.62, 0.2, 0.55, 0.3, 0.6, 0.4, 0.52, 0.5, 0.58], color: .ink, width: 0.01)]
        s1.note = "드론 샷으로 시작, 자막 페이드 인"
        var s2 = StoryScene(aspect: .r16x9, background: RGBA(r: 0.12, g: 0.13, b: 0.18))
        s2.items = [
            SceneItem(kind: .roundedRect, x: 0.3, y: 0.5, w: 0.34, h: 0.62, color: RGBA(r: 0.24, g: 0.49, b: 0.95)),
            SceneItem(kind: .arrow, x: 0.6, y: 0.5, w: 0.18, h: 0.16, color: .white),
            SceneItem(kind: .star, x: 0.82, y: 0.5, w: 0.16, h: 0.28, color: RGBA(r: 0.99, g: 0.72, b: 0.22)),
            SceneItem(kind: .text, x: 0.5, y: 0.9, w: 0.8, h: 0.14, color: .white, text: "메뉴 고르기 → 첫 한 모금", fontSize: 0.09),
        ]
        s2.note = "핸드헬드, 컷 빠르게"
        var s3 = StoryScene(aspect: .r16x9, background: .white)
        s3.items = [
            SceneItem(kind: .triangle, x: 0.25, y: 0.55, w: 0.28, h: 0.5, color: RGBA(r: 0.95, g: 0.36, b: 0.33)),
            SceneItem(kind: .text, x: 0.68, y: 0.5, w: 0.5, h: 0.3, color: .ink, text: "구독 · 좋아요\n다음 편에 계속", fontSize: 0.1),
        ]
        s3.strokes = [Stroke(points: [0.6, 0.75, 0.68, 0.8, 0.76, 0.75, 0.84, 0.8], color: RGBA(r: 0.95, g: 0.36, b: 0.33), width: 0.012)]
        s3.note = "엔딩 카드 3초"
        board.scenes = [s1, s2, s3]
        boards.insert(board, at: 0)
        selectedBoardID = board.id
        if let musicPath { setMusic(path: musicPath) }
        scheduleSave()
    }
}

// MARK: - Pop-out window

@MainActor
final class StoryboardWindowController {
    private let window: NSWindow

    init(store: StoryboardStore) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "스토리보드"
        window.minSize = NSSize(width: 640, height: 520)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StoryboardView(store: store, inWindow: true))
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
