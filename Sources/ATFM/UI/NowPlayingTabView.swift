import SwiftUI

struct NowPlayingTabView: View {
    var monitor: NowPlayingMonitor
    var controller: MiniPlayerController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                nowPlayingCard
                settingsCard
                if let error = monitor.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 4)
                }
                Text("Spotify 앱, 브라우저의 Spotify 웹 플레이어, 그 밖의 음악 앱이 재생 중일 때 화면 구석에 작은 플레이어가 떠요. 플레이어의 ✕를 누르면 여기서 다시 켤 때까지 숨겨집니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
    }

    private var header: some View {
        HStack {
            Text("미니 플레이어")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            statusChip
        }
        .padding(.horizontal, 2)
    }

    private var statusChip: some View {
        let (text, color): (String, Color) = {
            guard let track = monitor.track else { return ("재생 없음", .secondary) }
            return track.isPlaying ? ("재생 중", .green) : ("일시정지", .orange)
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let track = monitor.track {
                HStack(spacing: 12) {
                    ArtworkView(image: monitor.artwork, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        if !track.album.isEmpty {
                            Text(track.album).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Text(track.sourceName ?? track.sourceBundleID ?? "알 수 없는 앱")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.chipFill(scheme)))
                    }
                    Spacer(minLength: 0)
                }
                ProgressLine(track: track, now: monitor.now)
                HStack {
                    Spacer()
                    TransportControls(monitor: monitor, size: 16)
                    Spacer()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("재생 중인 곡이 없어요")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Spotify에서 노래를 틀면 자동으로 플레이어가 떠요")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Button("Spotify 열기") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
        .padding(12)
        .card()
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            settingRow("미니 플레이어 표시", "끄면(플레이어의 ✕와 같음) 다시 켤 때까지 숨겨요") {
                Toggle("", isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider().padding(.horizontal, 12)
            settingRow("표시할 소스", nil) {
                Picker("", selection: Binding(get: { controller.sourceFilter }, set: { controller.setSourceFilter($0) })) {
                    ForEach(MiniPlayerSourceFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 150)
            }
            Divider().padding(.horizontal, 12)
            settingRow("일시정지 중에도 표시", "끄면 재생 중일 때만 보여요") {
                Toggle("", isOn: Binding(get: { controller.showWhenPaused }, set: { controller.setShowWhenPaused($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider().padding(.horizontal, 12)
            settingRow("위치", "플레이어를 드래그해 옮기면 그 자리를 기억해요") {
                Picker("", selection: Binding(get: { controller.corner }, set: { controller.setCorner($0) })) {
                    ForEach(MiniPlayerCorner.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 118)
            }
        }
        .card()
    }

    private func settingRow<Control: View>(_ title: String, _ subtitle: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
