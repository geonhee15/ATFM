import SwiftUI

/// Tiny Markdown subset for chat bubbles. Unlike CommonMark it also bolds `**단어**를` (Korean particles
/// glued to the closing marker), and it turns headers and list markers into plain, readable text.
enum MarkdownLite {
    static func render(_ text: String, fontSize: CGFloat = 13) -> AttributedString {
        var result = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            var line = String(rawLine)
            var isHeader = false
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(range)
                isHeader = true
            }
            if let range = line.range(of: #"^\s*[-*•]\s+"#, options: .regularExpression) {
                line.replaceSubrange(range, with: "•  ")
            }
            result += renderInline(line, fontSize: fontSize, bold: isHeader)
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    private static let inlinePattern = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|`([^`]+)`"#)

    private static func renderInline(_ line: String, fontSize: CGFloat, bold: Bool) -> AttributedString {
        var output = AttributedString()
        let ns = line as NSString
        var cursor = 0
        for match in inlinePattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                output += styled(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                                 fontSize: fontSize, bold: bold, code: false)
            }
            if match.range(at: 1).location != NSNotFound {
                output += styled(ns.substring(with: match.range(at: 1)), fontSize: fontSize, bold: true, code: false)
            } else if match.range(at: 2).location != NSNotFound {
                output += styled(ns.substring(with: match.range(at: 2)), fontSize: fontSize, bold: bold, code: true)
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            output += styled(ns.substring(from: cursor), fontSize: fontSize, bold: bold, code: false)
        }
        return output
    }

    private static func styled(_ text: String, fontSize: CGFloat, bold: Bool, code: Bool) -> AttributedString {
        var piece = AttributedString(text)
        if code {
            piece.swiftUI.font = .system(size: fontSize - 1, weight: bold ? .semibold : .regular, design: .monospaced)
        } else if bold {
            piece.swiftUI.font = .system(size: fontSize, weight: .semibold)
        }
        return piece
    }

    /// "출처: title · title" with clickable links.
    static func sourcesLine(_ sources: [WebSource]) -> AttributedString {
        var result = AttributedString("출처: ")
        for (index, source) in sources.prefix(5).enumerated() {
            var link = AttributedString(source.title)
            link.link = URL(string: source.uri)
            link.swiftUI.foregroundColor = .accentColor
            result += link
            if index < min(sources.count, 5) - 1 { result += AttributedString(" · ") }
        }
        return result
    }
}
