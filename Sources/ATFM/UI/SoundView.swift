import SwiftUI

struct SoundView: View {
    @Bindable var panel: SoundPanel
    var master: SystemVolume
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                masterCard
                channelsCard
                appsCard
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
    }

    private var header: some View {
        HStack {
            Text("사운드")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(panel.deviceName.isEmpty ? "출력 장치 없음" : panel.deviceName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    private var masterCard: some View {
        HStack(spacing: 10) {
            Button { master.toggleMute() } label: {
                Image(systemName: master.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .help(master.isMuted ? "음소거 해제" : "음소거")
            Text("전체")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { master.isMuted ? 0 : master.volume }, set: { master.setVolume($0) }), in: 0...1)
                .controlSize(.small)
            Text("\(Int((master.volume * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private var channelsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("좌우 출력")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("가운데로") { panel.centerChannels() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .disabled(!panel.channelsAvailable)
            }
            if panel.channelsAvailable {
                channelRow("왼쪽", symbol: "l.circle", value: panel.left) { panel.setChannel(left: $0) }
                channelRow("오른쪽", symbol: "r.circle", value: panel.right) { panel.setChannel(right: $0) }
                Text("채널마다 따로 조절해요. 한쪽을 내리면 소리가 그쪽으로 치우쳐요.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("이 출력 장치는 채널별 볼륨 조절을 지원하지 않아요 (HDMI · 일부 외장 장치).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private func channelRow(_ label: String, symbol: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
                .controlSize(.small)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("앱별 볼륨")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if panel.apps.contains(where: { $0.volume < 0.999 }) {
                    Button("모두 100%") { panel.resetAllVolumes() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            if !panel.supported {
                Text("앱별 볼륨은 macOS 14.2 이상에서만 가능해요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if panel.apps.isEmpty {
                Text("지금 소리를 내는 앱이 없어요. 재생을 시작하면 여기에 나타나요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(panel.apps) { app in
                    HStack(spacing: 10) {
                        ProcessIcon(bundlePath: app.bundlePath, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(app.isPlaying ? "재생 중" : "대기").font(.system(size: 9)).foregroundStyle(app.isPlaying ? Color.green : Color.secondary)
                        }
                        .frame(width: 88, alignment: .leading)
                        Slider(value: Binding(get: { app.volume }, set: { panel.setVolume($0, for: app) }), in: 0...1)
                            .controlSize(.small)
                        Text("\(Int((app.volume * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(app.volume < 0.999 ? Theme.accent : Color.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }
            if let error = panel.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("100%가 기본이에요. 낮추면 그 앱 소리만 ATFM이 가로채 줄여서 내보내요(시스템 오디오 녹음 권한 사용). 앱을 다시 켜도 기억해요.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }
}
