import AppKit
import Vision

/// Vision text recognition tuned for Korean + English screen content.
enum ScreenOCR {
    static func recognize(_ image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let wanted = ["ko-KR", "en-US"]
                if let supported = try? request.supportedRecognitionLanguages() {
                    let picked = wanted.filter { supported.contains($0) }
                    if !picked.isEmpty { request.recognitionLanguages = picked }
                } else {
                    request.recognitionLanguages = wanted
                }
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let observations = (request.results ?? []) as [VNRecognizedTextObservation]
                    continuation.resume(returning: assemble(observations))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Groups observations into visual lines (top → bottom, left → right) and joins them.
    static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        struct Line {
            var y: CGFloat
            var height: CGFloat
            var parts: [(x: CGFloat, text: String)]
        }
        var lines: [Line] = []
        for observation in observations.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            if let index = lines.lastIndex(where: { abs($0.y - box.midY) < max($0.height, box.height) * 0.5 }) {
                lines[index].parts.append((box.minX, candidate.string))
            } else {
                lines.append(Line(y: box.midY, height: box.height, parts: [(box.minX, candidate.string)]))
            }
        }
        return lines
            .map { $0.parts.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
