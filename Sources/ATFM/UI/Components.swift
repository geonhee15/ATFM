import SwiftUI

enum Format {
    private static let memoryFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let decimalFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func memory(_ bytes: UInt64) -> String {
        memoryFormatter.string(fromByteCount: Int64(bytes))
    }

    static func bytes(_ bytes: UInt64) -> String {
        decimalFormatter.string(fromByteCount: Int64(bytes))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1000 { return "\(Int(value)) B/s" }
        return decimalFormatter.string(fromByteCount: Int64(value)) + "/s"
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    static func mbps(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    static func celsius(_ value: Double) -> String {
        String(format: "%.0f °C", value)
    }

    static func milliwatts(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.2f W", value / 1000) : String(format: "%.0f mW", value)
    }
}

struct Sparkline: View {
    var values: [Double]
    var maxValue: Double? = nil
    var color: Color = .accentColor
    var capacity: Int = 60

    var body: some View {
        GeometryReader { geo in
            let points = points(in: geo.size)
            if points.count > 1 {
                area(points, height: geo.size.height)
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                line(points)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let peak = max(maxValue ?? (values.max() ?? 1), 0.0001)
        let slots = max(1, capacity - 1)
        let offset = capacity - values.count
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(offset + index) / CGFloat(slots)
            let y = size.height - 1 - CGFloat(min(1, max(0, value / peak))) * (size.height - 2)
            return CGPoint(x: x, y: y)
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: height))
        path.addLines(points)
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.closeSubpath()
        return path
    }
}

struct UsageBar: View {
    var fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

struct StatTile: View {
    var title: String
    var systemImage: String
    var value: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chipFill(scheme)))
    }
}

struct MetricRow: View {
    var title: String
    var valueText: String
    var fraction: Double
    var color: Color
    var history: [Double]
    var historyMax: Double = 100
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 52, alignment: .leading)
                UsageBar(fraction: fraction, color: color)
                Text(valueText)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 62)
            }
            Sparkline(values: history, maxValue: historyMax, color: color)
                .frame(height: 22)
                .padding(.leading, 62)
                .padding(.trailing, 68)
        }
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// Icon for an app (bundle) or a plain process.
struct ProcessIcon: View {
    var bundlePath: String?
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let bundlePath {
            Image(nsImage: AppIconCache.icon(for: SourceApp(name: nil, bundleID: nil, path: bundlePath), size: 32))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Theme.chipFill(scheme)))
        }
    }
}

struct AppUsageRow: View {
    var bundlePath: String?
    var name: String
    var value: String
    var detail: String?
    var fraction: Double
    var color: Color

    var body: some View {
        HStack(spacing: 10) {
            ProcessIcon(bundlePath: bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                UsageBar(fraction: fraction, color: color, height: 5)
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
