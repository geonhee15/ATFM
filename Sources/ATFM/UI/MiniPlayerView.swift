import SwiftUI

/// Content of the floating mini player.
struct MiniPlayerView: View {
    var monitor: NowPlayingMonitor
    var controller: MiniPlayerController
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 12) {
                ArtworkView(image: monitor.artwork, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.track?.title ?? "재생 중인 곡 없음")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(monitor.track?.artist ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    ProgressLine(track: monitor.track, now: monitor.now)
                }
                TransportControls(monitor: monitor, size: 14)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 12)

            Button { controller.dismissByUser() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .padding(6)
            .help("닫기 (ATFM에서 다시 켤 수 있어요)")
        }
        .frame(width: MiniPlayerController.size.width, height: MiniPlayerController.size.height)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.cardStroke(scheme), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .onHover { hovering = $0 }
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.chipFill(scheme)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

struct ProgressLine: View {
    var track: NowPlayingTrack?
    var now: Date

    private var elapsed: Double { track?.currentElapsed(at: now) ?? 0 }
    private var duration: Double { track?.duration ?? 0 }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: duration > 0 ? geo.size.width * CGFloat(min(1, elapsed / duration)) : 0)
                }
            }
            .frame(height: 3)
            HStack {
                Text(Self.format(elapsed))
                Spacer()
                Text(duration > 0 ? Self.format(duration) : "")
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TransportControls: View {
    var monitor: NowPlayingMonitor
    var size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.7) {
            control("backward.fill", size: size) { monitor.previous() }
            control(monitor.track?.isPlaying == true ? "pause.fill" : "play.fill", size: size * 1.35) { monitor.togglePlayPause() }
            control("forward.fill", size: size) { monitor.next() }
        }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size * 1.8, height: size * 1.8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
