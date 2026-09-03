import Foundation
import CryptoKit

enum ClipKind: Int {
    case text = 0
    case image = 1
    case files = 2

    var label: String {
        switch self {
        case .text: return "텍스트"
        case .image: return "이미지"
        case .files: return "파일"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }
}

/// The application that was frontmost when the copy happened.
struct SourceApp: Hashable {
    var name: String?
    var bundleID: String?
    var path: String?

    var displayName: String { name ?? "알 수 없는 앱" }
    var cacheKey: String { bundleID ?? path ?? name ?? "unknown" }
}

/// One clipboard history entry (metadata only; image blobs live in the store).
struct ClipItem: Identifiable, Hashable {
    let id: Int64
    var createdAt: Date
    let kind: ClipKind
    /// Text content, newline-joined file paths, or the text that accompanied an image.
    let text: String
    var app: SourceApp
    let byteCount: Int
    let imageWidth: Int
    let imageHeight: Int
    let hash: String

    var filePaths: [String] {
        guard kind == .files else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    var previewText: String {
        String(text.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var detailLabel: String {
        switch kind {
        case .text:
            return "텍스트 · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
        case .image:
            return "이미지 · \(imageWidth)×\(imageHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
        case .files:
            let n = filePaths.count
            return n == 1 ? "파일 1개" : "파일 \(n)개"
        }
    }
}

/// A freshly captured pasteboard change, before it is persisted.
struct CapturedClip {
    enum Payload {
        case text(String)
        case image(png: Data, thumb: Data?, width: Int, height: Int, text: String?)
        case files([URL])
    }

    let payload: Payload
    let source: SourceApp
    let date: Date

    var kind: ClipKind {
        switch payload {
        case .text: return .text
        case .image: return .image
        case .files: return .files
        }
    }

    var text: String {
        switch payload {
        case .text(let s): return s
        case .image(_, _, _, _, let t): return t ?? ""
        case .files(let urls): return urls.map(\.path).joined(separator: "\n")
        }
    }

    var byteCount: Int {
        switch payload {
        case .text(let s): return s.utf8.count
        case .image(let png, _, _, _, _): return png.count
        case .files(let urls): return urls.count
        }
    }

    var hash: String {
        switch payload {
        case .text(let s): return "t:" + Hashing.sha256(Data(s.utf8))
        case .image(let png, _, _, _, _): return "i:" + Hashing.sha256(png)
        case .files(let urls): return "f:" + Hashing.sha256(Data(urls.map(\.path).joined(separator: "\n").utf8))
        }
    }
}

enum Hashing {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
