import CoreGraphics
import Vision

/// Works out which part of a chat window to cover, from a capture of that window:
/// - the chat area's top (below title bar, room header and a pinned notice) from background colours,
/// - message blocks from text line rectangles clustered by vertical gap,
/// - the clear zone = the newest N blocks plus the composer strip at the bottom.
/// Coordinates are window points with the origin at the bottom-left.
enum ChatLayoutAnalyzer {
    struct Block: Equatable {
        var bottom: CGFloat
        var top: CGFloat
        var minX: CGFloat = 0
        var maxX: CGFloat = 0
    }

    struct Result: Equatable {
        /// Rect to cover before the clear zone is cut off its bottom (x, width, and top edge matter).
        var cover: CGRect
        /// Height (points from the window bottom) that must stay uncovered.
        var clearHeight: CGFloat
        var messageCount: Int
        var blocks: [Block]
        var detectedHeader: Bool
        var noticeHeight: CGFloat
    }

    static var lastDuration: TimeInterval = 0

    /// - panel: the region of the window that holds the chat (browser: from the page; native apps: whole window)
    /// - headerInset: fallback header height (from the panel top) when colours give nothing
    static func analyze(_ image: CGImage, windowSize: CGSize, panel: CGRect?, headerInset: CGFloat,
                        composerHeight: CGFloat, recentCount: Int) -> Result? {
        let started = Date()
        defer { lastDuration = Date().timeIntervalSince(started) }
        let region = (panel ?? CGRect(origin: .zero, size: windowSize)).intersection(CGRect(origin: .zero, size: windowSize))
        guard region.width > 50, region.height > 50 else { return nil }

        // Header / notice from colours (KakaoTalk-style: chat background differs from the header).
        var chatTop = region.maxY - headerInset
        var detectedHeader = false
        var noticeHeight: CGFloat = 0
        if let pixels = PixelReader(image: image, windowSize: windowSize) {
            if let top = pixels.chatAreaTop(in: region) {
                chatTop = top
                detectedHeader = true
                if let notice = pixels.noticeBand(in: region, chatTop: top) {
                    noticeHeight = notice
                    chatTop -= notice
                }
            }
        }

        // Text lines (rectangles only; nothing is recognised).
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        guard (try? handler.perform([request])) != nil else { return nil }
        var lines: [Block] = []
        for observation in (request.results ?? []) as [VNTextObservation] {
            let box = observation.boundingBox
            let block = Block(bottom: box.minY * windowSize.height, top: box.maxY * windowSize.height,
                              minX: box.minX * windowSize.width, maxX: box.maxX * windowSize.width)
            let height = block.top - block.bottom
            guard height >= 5, height <= 90, block.maxX - block.minX >= 6 else { continue }
            guard block.maxX > region.minX + 4, block.minX < region.maxX - 4 else { continue }   // outside the panel (side bars)
            guard block.top <= chatTop + 2 else { continue }                                       // header / notice
            lines.append(block)
        }
        var result = cluster(lines, windowHeight: windowSize.height, composerHeight: region.minY + composerHeight, recentCount: recentCount)
        result.cover = CGRect(x: region.minX, y: region.minY, width: region.width, height: max(0, chatTop - region.minY))
        result.detectedHeader = detectedHeader
        result.noticeHeight = noticeHeight
        return result
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
                last.minX = min(last.minX, line.minX)
                last.maxX = max(last.maxX, line.maxX)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(line)
            }
        }
        let messages = blocks.filter { $0.bottom >= composerHeight }
        let count = max(1, recentCount)
        let clear: CGFloat
        if messages.count >= count {
            clear = messages[count - 1].top + 10
        } else if let last = messages.last {
            clear = last.top + 10
        } else {
            clear = composerHeight + 150           // nothing detected: stay conservative
        }
        return Result(cover: .zero, clearHeight: min(clear, windowHeight), messageCount: messages.count, blocks: messages,
                      detectedHeader: false, noticeHeight: 0)
    }
}

/// Cheap per-pixel access to the window capture (nominal resolution: 1 px ≈ 1 pt, but we scale anyway).
struct PixelReader {
    private let data: CFData
    private let bytesPerRow: Int
    private let bytesPerPixel: Int
    private let width: Int
    private let height: Int
    private let scaleX: CGFloat
    private let scaleY: CGFloat

    init?(image: CGImage, windowSize: CGSize) {
        guard let provider = image.dataProvider, let data = provider.data, image.bitsPerPixel == 32 else { return nil }
        self.data = data
        bytesPerRow = image.bytesPerRow
        bytesPerPixel = 4
        width = image.width
        height = image.height
        scaleX = CGFloat(image.width) / windowSize.width
        scaleY = CGFloat(image.height) / windowSize.height
    }

    /// (r, g, b) at window point (x, y from the bottom).
    private func color(x: CGFloat, yFromBottom: CGFloat) -> (Int, Int, Int)? {
        let px = Int(x * scaleX), py = height - 1 - Int(yFromBottom * scaleY)
        guard px >= 0, px < width, py >= 0, py < height, let base = CFDataGetBytePtr(data) else { return nil }
        let p = base + py * bytesPerRow + px * bytesPerPixel
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    private static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }

    /// Background colour of the chat area: the mode of the left margin over the middle of the region.
    private func chatBackground(in region: CGRect) -> (Int, Int, Int)? {
        var counts: [String: (Int, (Int, Int, Int))] = [:]
        let x = region.minX + 3
        var y = region.minY + region.height * 0.35
        while y < region.minY + region.height * 0.65 {
            if let c = color(x: x, yFromBottom: y) {
                let key = "\(c.0 / 8)-\(c.1 / 8)-\(c.2 / 8)"
                counts[key] = ((counts[key]?.0 ?? 0) + 1, c)
            }
            y += 2
        }
        return counts.values.max { $0.0 < $1.0 }?.1
    }

    /// Top of the chat area (points from the window bottom): scanning down from the region top, the first
    /// row where the left margin turns into the chat background and stays so. nil when the header has the
    /// same colour as the chat (then the caller's fixed inset is used).
    func chatAreaTop(in region: CGRect) -> CGFloat? {
        guard let bg = chatBackground(in: region) else { return nil }
        let x = region.minX + 3
        let tolerance = 24
        var y = region.maxY - 1
        var run: CGFloat = 0
        var runStart: CGFloat = 0
        var sawOther = false
        while y > region.minY + region.height * 0.35 {
            guard let c = color(x: x, yFromBottom: y) else { break }
            if PixelReader.distance(c, bg) <= tolerance {
                if run == 0 { runStart = y }
                run += 1
                if run >= 24 { return sawOther ? runStart + 1 : nil }
            } else {
                run = 0
                sawOther = true
            }
            y -= 1
        }
        return nil
    }

    /// Height of a pinned-notice bar sitting at the very top of the chat area: a band of rows whose central
    /// 84% is almost entirely non-background (message bubbles never span that wide).
    func noticeBand(in region: CGRect, chatTop: CGFloat) -> CGFloat? {
        guard let bg = chatBackground(in: region) else { return nil }
        let left = region.minX + region.width * 0.08, right = region.maxX - region.width * 0.08
        var y = chatTop - 1
        var bandStart: CGFloat?
        var bandEnd: CGFloat?
        var gap: CGFloat = 0
        while y > chatTop - 110, y > region.minY {
            var wide = 0, total = 0
            var x = left
            while x < right {
                if let c = color(x: x, yFromBottom: y) { total += 1; if PixelReader.distance(c, bg) > 24 { wide += 1 } }
                x += 4
            }
            let isWide = total > 0 && Double(wide) / Double(total) > 0.85
            if isWide {
                if bandStart == nil { bandStart = y }
                bandEnd = y
                gap = 0
            } else if bandStart != nil {
                gap += 1
                if gap > 4 { break }
            } else if chatTop - y > 30 {
                return nil                                   // nothing wide right under the header
            }
            y -= 1
        }
        guard let start = bandStart, let end = bandEnd, start - end >= 14 else { return nil }
        return chatTop - end + 6
    }
}
