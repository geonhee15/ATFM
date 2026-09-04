import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaKind: String, CaseIterable, Identifiable {
    case image, video, audio
    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "이미지"
        case .video: return "영상"
        case .audio: return "오디오"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }

    static func detect(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        if ["mkv", "webm", "avi", "wmv", "flv", "ts", "m2ts", "mpg", "mpeg", "3gp", "vob", "ogv", "mts"].contains(ext) { return .video }
        if ["ogg", "oga", "opus", "wma", "amr", "ape", "mka", "ac3", "dts", "mp2"].contains(ext) { return .audio }
        if ["webp", "avif", "heic", "heif", "jxl", "psd", "cr2", "nef", "arw", "dng", "raf", "orf"].contains(ext) { return .image }
        return nil
    }
}

enum ConvertEngine {
    case imageIO, ffmpeg, avFoundation
}

struct OutputFormat: Identifiable, Hashable {
    let id: String
    let title: String
    let ext: String
    /// Kind of the produced file (video sources can produce audio-only outputs).
    let kind: MediaKind
    let lossy: Bool
    var utType: String? = nil

    static let imageAll: [OutputFormat] = [
        OutputFormat(id: "png", title: "PNG", ext: "png", kind: .image, lossy: false, utType: "public.png"),
        OutputFormat(id: "jpeg", title: "JPEG", ext: "jpg", kind: .image, lossy: true, utType: "public.jpeg"),
        OutputFormat(id: "heic", title: "HEIC", ext: "heic", kind: .image, lossy: true, utType: "public.heic"),
        OutputFormat(id: "avif", title: "AVIF", ext: "avif", kind: .image, lossy: true, utType: "public.avif"),
        OutputFormat(id: "tiff", title: "TIFF", ext: "tiff", kind: .image, lossy: false, utType: "public.tiff"),
        OutputFormat(id: "gif", title: "GIF", ext: "gif", kind: .image, lossy: false, utType: "com.compuserve.gif"),
        OutputFormat(id: "bmp", title: "BMP", ext: "bmp", kind: .image, lossy: false, utType: "com.microsoft.bmp"),
    ]

    /// Only the image types ImageIO on this Mac can actually write.
    static let image: [OutputFormat] = {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return imageAll.filter { $0.utType.map { writable.contains($0) } ?? false }
    }()

    static let videoFFmpeg: [OutputFormat] = [
        OutputFormat(id: "mp4-h264", title: "MP4 (H.264)", ext: "mp4", kind: .video, lossy: true),
        OutputFormat(id: "mp4-hevc", title: "MP4 (HEVC)", ext: "mp4", kind: .video, lossy: true),
        OutputFormat(id: "mov-h264", title: "MOV (H.264)", ext: "mov", kind: .video, lossy: true),
        OutputFormat(id: "mov-hevc", title: "MOV (HEVC)", ext: "mov", kind: .video, lossy: true),
        OutputFormat(id: "mkv-h264", title: "MKV (H.264)", ext: "mkv", kind: .video, lossy: true),
        OutputFormat(id: "webm-vp9", title: "WebM (VP9)", ext: "webm", kind: .video, lossy: true),
        OutputFormat(id: "gif-anim", title: "GIF (움직이는)", ext: "gif", kind: .video, lossy: true),
    ]

    static let audioFFmpeg: [OutputFormat] = [
        OutputFormat(id: "mp3", title: "MP3", ext: "mp3", kind: .audio, lossy: true),
        OutputFormat(id: "m4a", title: "M4A (AAC)", ext: "m4a", kind: .audio, lossy: true),
        OutputFormat(id: "wav", title: "WAV", ext: "wav", kind: .audio, lossy: false),
        OutputFormat(id: "flac", title: "FLAC", ext: "flac", kind: .audio, lossy: false),
        OutputFormat(id: "aiff", title: "AIFF", ext: "aiff", kind: .audio, lossy: false),
        OutputFormat(id: "ogg-opus", title: "OGG (Opus)", ext: "ogg", kind: .audio, lossy: true),
    ]

    // Without ffmpeg only what AVFoundation can export.
    static let videoBuiltin: [OutputFormat] = [
        OutputFormat(id: "mp4-h264", title: "MP4 (H.264)", ext: "mp4", kind: .video, lossy: true),
        OutputFormat(id: "mp4-hevc", title: "MP4 (HEVC)", ext: "mp4", kind: .video, lossy: true),
        OutputFormat(id: "mov-h264", title: "MOV (H.264)", ext: "mov", kind: .video, lossy: true),
    ]
    static let audioBuiltin: [OutputFormat] = [
        OutputFormat(id: "m4a", title: "M4A (AAC)", ext: "m4a", kind: .audio, lossy: true),
    ]
}

enum VideoResolution: Int, CaseIterable, Identifiable {
    case original = 0, p1080 = 1080, p720 = 720, p480 = 480
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .original: return "원본 해상도"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case high, medium, low
    var id: String { rawValue }
    var title: String {
        switch self {
        case .high: return "고화질"
        case .medium: return "보통"
        case .low: return "작게"
        }
    }
    /// VideoToolbox -q:v (1–100), libx264 crf, libvpx-vp9 crf
    var vtQuality: Int { self == .high ? 75 : (self == .medium ? 60 : 45) }
    var x264CRF: Int { self == .high ? 18 : (self == .medium ? 23 : 28) }
    var vp9CRF: Int { self == .high ? 28 : (self == .medium ? 33 : 38) }
}

enum ImageMaxSize: Int, CaseIterable, Identifiable {
    case original = 0, s4096 = 4096, s2048 = 2048, s1024 = 1024, s512 = 512
    var id: Int { rawValue }
    var title: String { self == .original ? "원본 크기" : "최대 \(rawValue)px" }
}

enum ConvertError: LocalizedError {
    case unsupported(String)
    case failed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .unsupported(let what): return "지원하지 않는 형식: \(what)"
        case .failed(let message): return message
        case .cancelled: return "중단됨"
        }
    }
}
