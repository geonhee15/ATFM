import SwiftUI

/// Content of the floating mini player.
struct MiniPlayerView: View {
    var monitor: NowPlayingMonitor
    var controller: MiniPlayerController
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            playerRow
                .frame(height: MiniPlayerController.size.height)
            if controller.isLyricsExpanded {
                Divider().padding(.horizontal, 12)
                LyricsBox(lyrics: controller.lyrics, monitor: monitor)
                    .frame(height: MiniPlayerController.lyricsHeight)
            }
        }
        .frame(width: controller.currentSize.width, height: controller.currentSize.height, alignment: .top)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.cardStroke(scheme), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .onHover { hovering = $0 }
    }

    private var playerRow: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 12) {
                ArtworkView(image: monitor.artwork, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.track?.title ?? "재생 중인 곡 없음")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .padding(.trailing, 36)
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

            HStack(spacing: 4) {
                Button { controller.setLyricsExpanded(!controller.isLyricsExpanded) } label: {
                    Image(systemName: "music.mic")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(controller.isLyricsExpanded ? Theme.accent : Color.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(controller.isLyricsExpanded ? "가사 닫기" : "가사 보기")
                Button { controller.dismissByUser() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("닫기 (ATFM에서 다시 켤 수 있어요)")
            }
            .opacity(hovering || controller.isLyricsExpanded ? 1 : 0.4)
            .padding(6)
        }
    }
}

struct LyricsBox: View {
    var lyrics: LyricsController
    var monitor: NowPlayingMonitor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "music.mic").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("가사").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if lyrics.lyrics?.isSynced == true {
                    Text("싱크")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
                if let source = lyrics.lyrics?.source, source != "LRCLIB" {
                    Text(source).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer()
                if lyrics.lyrics?.isSynced == true, !lyrics.isEditing {
                    offsetControls
                }
                lyricsMenu
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
            if lyrics.isEditing { editor } else { content }
        }
    }

    private var lyricsMenu: some View {
        Menu {
            if lyrics.candidates.isEmpty {
                Button {
                    lyrics.loadCandidates()
                } label: {
                    Label(lyrics.isLoadingCandidates ? "후보 찾는 중…" : "다른 가사 찾기", systemImage: "magnifyingglass")
                }
                .disabled(lyrics.isLoadingCandidates)
            } else {
                Section("가사 후보 \(lyrics.candidates.count)개 · 한글·싱크·길이 일치 우선") {
                    ForEach(lyrics.candidates) { candidate in
                        Button {
                            lyrics.choose(candidate)
                        } label: {
                            if candidate.id == lyrics.selectedCandidateID {
                                Label(candidate.summary, systemImage: "checkmark")
                            } else {
                                Text(candidate.summary)
                            }
                        }
                    }
                }
            }
            Divider()
            Button { lyrics.retry() } label: { Label("다시 검색", systemImage: "arrow.clockwise") }
            Button { lyrics.beginEditing() } label: { Label("직접 입력…", systemImage: "square.and.pencil") }
            Button { lyrics.importLRCFile() } label: { Label("LRC 파일 가져오기…", systemImage: "doc.badge.plus") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("다른 가사 고르기 · 직접 입력")
    }

    private var editor: some View {
        VStack(spacing: 6) {
            TextEditor(text: Binding(get: { lyrics.draft }, set: { lyrics.draft = $0 }))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill(scheme)))
            HStack {
                Text("[mm:ss.xx] 가사 형식이면 싱크로 표시돼요")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("취소") { lyrics.isEditing = false }
                Button("저장") { lyrics.saveDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(lyrics.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// −0.5 / +0.5 second nudges; tap the value to reset. Remembered per song.
    private var offsetControls: some View {
        HStack(spacing: 2) {
            nudgeButton("minus", help: "가사를 0.5초 늦게") { lyrics.adjustOffset(by: -LyricsController.offsetStep) }
            Button { lyrics.resetOffset() } label: {
                Text(lyrics.offsetLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(lyrics.offset == 0 ? Color.secondary : Theme.accent)
                    .frame(minWidth: 38)
            }
            .buttonStyle(.plain)
            .help("싱크 보정값 (누르면 0으로)")
            nudgeButton("plus", help: "가사를 0.5초 빨리") { lyrics.adjustOffset(by: LyricsController.offsetStep) }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.chipFill(scheme)))
    }

    private func nudgeButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var content: some View {
        switch lyrics.state {
        case .idle, .loading:
            centered {
                ProgressView().controlSize(.small)
                Text("가사 찾는 중…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .notFound:
            centered {
                Image(systemName: "text.badge.xmark").font(.system(size: 18)).foregroundStyle(.tertiary)
                Text("이 곡의 가사를 찾지 못했어요").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .failed(let message):
            centered {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("다시 시도") { lyrics.retry() }.controlSize(.small)
            }
        case .found(let found):
            if let lines = found.synced, !lines.isEmpty {
                SyncedLyricsList(lines: lines, currentIndex: lyrics.currentLineIndex(at: monitor.now)) { line in
                    lyrics.seek(to: line)
                }
            } else {
                ScrollView {
                    Text(found.plain ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 14)
    }
}

struct SyncedLyricsList: View {
    let lines: [LyricLine]
    let currentIndex: Int?
    let onTap: (LyricLine) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(lines) { line in
                        let isCurrent = line.id == currentIndex
                        let isPast = currentIndex.map { line.id < $0 } ?? false
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: isCurrent ? 14 : 13, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                            .opacity(isPast ? 0.55 : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(line) }
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 90)
            }
            .onChange(of: currentIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear {
                if let currentIndex { proxy.scrollTo(currentIndex, anchor: .center) }
            }
        }
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
                        .fill(Theme.accent)
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
