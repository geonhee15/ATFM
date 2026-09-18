import CoreGraphics
import Vision

/// Finds where the "recent messages" zone of a chat window starts, from a capture of that window.
/// Text line rectangles (no recognition — just boxes) are clustered into message blocks by vertical
/// gaps; blocks inside the composer strip at the bottom are ignored; the N most recent blocks above
/// the composer stay clear and everything above them gets covered.
enum ChatLayoutAnalyzer {
    struct Block: Equatable {
        var bottom: CGFloat   // points from the window bottom
        var top: CGFloat
    }

    struct Result: Equatable {
        /// Height (points from the window bottom) that must stay uncovered.
        var clearHeight: CGFloat
        /// Height above which the blur must be fully opaque (the feather lives between the two).
        var opaqueHeight: CGFloat
        var messageCount: Int
        var blocks: [Block]
    }

    static var lastDuration: TimeInterval = 0

    /// Rectangle detection (not recognition): ~7 ms per window and, in testing, more complete than
    /// fast-level text recognition, which merged/missed whole lines. Very short bubbles ("넵!") and
    /// small timestamps can still go undetected, which is why the feather is capped at 16 pt.
    static func analyze(_ image: CGImage, windowHeight: CGFloat, composerHeight: CGFloat, recentCount: Int) -> Result? {
        let started = Date()
        defer { lastDuration = Date().timeIntervalSince(started) }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        guard (try? handler.perform([request])) != nil else { return nil }
        let boxes = ((request.results ?? []) as [VNTextObservation]).map(\.boundingBox)
        let width = CGFloat(image.width) * windowHeight / CGFloat(image.height)
        var lines: [Block] = []
        for box in boxes {
            let height = box.height * windowHeight
            guard height >= 5, height <= 90, box.width * width >= 6 else { continue }
            lines.append(Block(bottom: box.minY * windowHeight, top: box.maxY * windowHeight))
        }
        return cluster(lines, windowHeight: windowHeight, composerHeight: composerHeight, recentCount: recentCount)
    }

    static func cluster(_ lines: [Block], windowHeight: CGFloat, composerHeight: CGFloat, recentCount: Int) -> Result {
        let sorted = lines.sorted { $0.bottom < $1.bottom }
        let heights = sorted.map { $0.top - $0.bottom }.sorted()
        let median = heights.isEmpty ? 14 : heights[heights.count / 2]
        let threshold = max(14, median * 1.1)      // gap between lines of the same message block
        var blocks: [Block] = []
        for line in sorted {
            if var last = blocks.last, line.bottom - last.top <= threshold {
                last.top = max(last.top, line.top)
                last.bottom = min(last.bottom, line.bottom)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(line)
            }
        }
        let messages = blocks.filter { $0.bottom >= composerHeight }
        let count = max(1, recentCount)
        let clear: CGFloat
        var opaque: CGFloat
        if messages.count >= count {
            clear = messages[count - 1].top + 10
            // Feather inside the gap: solid by the bottom of the next-older message (bubble padding included).
            opaque = messages.count > count ? messages[count].bottom - 6 : clear + 18
        } else if let last = messages.last {
            clear = last.top + 10
            opaque = clear + 18
        } else {
            clear = composerHeight + 150           // nothing detected: stay conservative
            opaque = clear + 18
        }
        opaque = min(max(opaque, clear + 8), clear + 16)
        return Result(clearHeight: min(clear, windowHeight), opaqueHeight: min(opaque, windowHeight), messageCount: messages.count, blocks: messages)
    }
}
