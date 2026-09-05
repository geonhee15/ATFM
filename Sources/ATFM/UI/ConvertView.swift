import SwiftUI

struct ConvertView: View {
    @Bindable var converter: FileConverter
    @Bindable var downloader: MediaDownloader
    @State private var dropTargeted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    DownloadCard(downloader: downloader, converter: converter)
                    dropZone
                    if converter.ffmpeg == nil { ffmpegHint }
                    ForEach(MediaKind.allCases) { kind in
                        let items = converter.items(of: kind)
                        if !items.isEmpty { groupCard(kind: kind, items: items) }
                    }
                }
                .padding(.bottom, 6)
            }
            if !converter.items.isEmpty { bottomBar }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("파일 변환 · 다운로드")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(converter.engineName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.chipFill(scheme)))
            Spacer()
            Menu {
                Section("저장 위치") {
                    Button { converter.outputLocation = .sameFolder } label: { locationLabel("원본과 같은 폴더", selected: converter.outputLocation == .sameFolder) }
                    Button { converter.outputLocation = .downloads } label: { locationLabel("다운로드 폴더", selected: converter.outputLocation == .downloads) }
                    Button { converter.chooseOutputFolder() } label: {
                        if case .custom(let url) = converter.outputLocation {
                            Label(url.lastPathComponent + "…", systemImage: "checkmark")
                        } else {
                            Text("다른 폴더 선택…")
                        }
                    }
                }
                Divider()
                Button { converter.resetFinished() } label: { Label("완료 항목 다시 변환", systemImage: "arrow.counterclockwise") }
                    .disabled(converter.isRunning || converter.doneCount == 0)
                Button(role: .destructive) { converter.clear() } label: { Label("목록 비우기", systemImage: "trash") }
                    .disabled(converter.items.isEmpty)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func locationLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(dropTargeted ? Theme.accent : Color.secondary)
            Text(dropTargeted ? "여기에 놓으세요" : "파일을 여기에 끌어다 놓거나 클릭해서 선택")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(dropTargeted ? Theme.accent : Color.primary)
            Text("이미지 · 영상 · 오디오 · 여러 개 한 번에")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropTargeted ? Theme.accent : Color.secondary.opacity(0.5))
        )
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dropTargeted ? Theme.accent.opacity(0.08) : Theme.cardFill(scheme)))
        .contentShape(Rectangle())
        .onTapGesture { converter.chooseFiles() }
        .dropDestination(for: URL.self) { urls, _ in
            converter.add(urls: urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var ffmpegHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("ffmpeg가 없어서 영상은 MP4/MOV, 오디오는 M4A만 됩니다.").font(.system(size: 11))
                Text("터미널에서 brew install ffmpeg 후 ATFM을 다시 실행하면 MP3 · MKV · WebM · FLAC 등이 추가돼요.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .card(radius: 10)
    }

    // MARK: Groups

    private func groupCard(kind: MediaKind, items: [ConvertItem]) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol).foregroundStyle(Theme.accent)
                    Text("\(kind.title) \(items.count)개").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    targetPicker(kind: kind)
                }
                optionsRow(kind: kind)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().padding(.horizontal, 12)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ConvertRow(item: item, thumbnail: converter.thumbnails[item.id], isQueueRunning: converter.isRunning,
                           onRemove: { converter.remove(item.id) }, onReveal: { url in converter.reveal(url) })
                if index < items.count - 1 { Divider().padding(.leading, 62) }
            }
        }
        .card()
    }

    @ViewBuilder
    private func targetPicker(kind: MediaKind) -> some View {
        switch kind {
        case .image:
            Picker("", selection: $converter.imageTarget) {
                ForEach(converter.imageFormats) { Text($0.title).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 110)
        case .video:
            Picker("", selection: $converter.videoTarget) {
                Section("영상") { ForEach(converter.videoFormats) { Text($0.title).tag($0) } }
                Section("오디오만 추출") { ForEach(converter.audioFormats) { Text($0.title).tag($0) } }
            }
            .labelsHidden().controlSize(.small).frame(width: 130)
        case .audio:
            Picker("", selection: $converter.audioTarget) {
                ForEach(converter.audioFormats) { Text($0.title).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 110)
        }
    }

    @ViewBuilder
    private func optionsRow(kind: MediaKind) -> some View {
        switch kind {
        case .image:
            HStack(spacing: 10) {
                if converter.imageTarget.lossy {
                    Text("품질 \(Int(converter.imageQuality * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 62, alignment: .leading)
                    Slider(value: $converter.imageQuality, in: 0.3...1.0).controlSize(.small)
                }
                Picker("", selection: $converter.imageMaxSize) {
                    ForEach(ImageMaxSize.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 110)
            }
        case .video:
            HStack(spacing: 8) {
                if converter.videoTarget.kind == .video {
                    Picker("", selection: $converter.videoResolution) {
                        ForEach(VideoResolution.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 118)
                    Picker("", selection: $converter.videoQuality) {
                        ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 90)
                } else if converter.videoTarget.lossy {
                    bitratePicker
                }
                Spacer()
            }
        case .audio:
            HStack {
                if converter.audioTarget.lossy { bitratePicker }
                Spacer()
            }
        }
    }

    private var bitratePicker: some View {
        Picker("", selection: $converter.audioBitrate) {
            ForEach(FileConverter.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
        }
        .labelsHidden().controlSize(.small).frame(width: 100)
    }

    // MARK: Bottom

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if converter.isRunning {
                ProgressView().controlSize(.small)
                Text("변환 중 · 완료 \(converter.doneCount)/\(converter.items.count)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Spacer()
                Button("중단") { converter.cancel() }.controlSize(.small)
            } else {
                Text("저장: \(converter.outputLocation.title)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    converter.run()
                } label: {
                    Label(converter.pendingCount > 0 ? "변환 시작 (\(converter.pendingCount)개)" : "모두 완료", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(converter.pendingCount == 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .card()
    }
}

struct ConvertRow: View {
    let item: ConvertItem
    let thumbnail: NSImage?
    let isQueueRunning: Bool
    let onRemove: () -> Void
    let onReveal: (URL) -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            thumbnailView
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                statusView
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Theme.hoverFill(scheme) : Color.clear)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.chipFill(scheme)))
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .waiting:
            Text(Format.bytes(UInt64(max(0, item.sizeBytes))) + " · 대기").font(.system(size: 10)).foregroundStyle(.secondary)
        case .running(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress).controlSize(.small)
                Text("\(Int(progress * 100))%").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
        case .done(let url):
            Text("완료 · " + url.lastPathComponent).font(.system(size: 10)).foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
        case .failed(let message):
            Text("실패 · " + message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text("중단됨").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case .done(let url):
            Button { onReveal(url) } label: {
                Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Finder에서 보기")
        case .running:
            EmptyView()
        default:
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering && !isQueueRunning ? 1 : 0)
            .help("목록에서 제거")
        }
    }
}


/// "링크 다운로드" card at the top of the convert tab (YouTube and anything yt-dlp handles).
struct DownloadCard: View {
    @Bindable var downloader: MediaDownloader
    var converter: FileConverter
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("링크 다운로드").font(.system(size: 13, weight: .semibold))
                Text("YouTube 등").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if downloader.isAvailable {
                    qualityMenu
                }
            }
            if downloader.isAvailable {
                urlField
                statusArea
                footer
            } else {
                Text("yt-dlp가 없어요. 터미널에서 brew install yt-dlp 후 ATFM을 다시 실행하면 여기서 바로 받을 수 있어요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .card()
        .onAppear { downloader.pasteIfLink() }
    }

    private var qualityMenu: some View {
        Menu {
            Picker("화질", selection: $downloader.quality) {
                ForEach(DownloadQuality.allCases) { q in
                    Text(q.title).tag(q)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(downloader.quality.title).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.chipFill(scheme)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(downloader.isBusy)
    }

    private var urlField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField("https://www.youtube.com/watch?v=…", text: $downloader.url)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .disabled(downloader.isBusy)
                .onSubmit { downloader.start() }
            if !downloader.url.isEmpty, !downloader.isBusy {
                Button { downloader.url = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                if let text = NSPasteboard.general.string(forType: .string) { downloader.url = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("클립보드의 링크 붙여넣기")
            .disabled(downloader.isBusy)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chipFill(scheme)))
    }

    @ViewBuilder
    private var statusArea: some View {
        switch downloader.phase {
        case .idle:
            Text(downloader.quality.subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
        case .fetchingInfo:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("영상 정보 확인 중…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .downloading, .merging:
            VStack(alignment: .leading, spacing: 4) {
                if !downloader.title.isEmpty {
                    Text(downloader.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                ProgressView(value: downloader.phase == .merging ? 1 : downloader.progress).controlSize(.small)
                HStack {
                    Text(downloader.phase == .merging ? (downloader.quality == .audioMP3 ? "오디오 변환 중…" : "영상·오디오 합치는 중…")
                         : "\(Int(downloader.progress * 100))% · \(downloader.sizeText)" + (downloader.speed.isEmpty ? "" : " · \(downloader.speed)") + (downloader.eta.isEmpty ? "" : " · 남은 \(downloader.eta)"))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Text(metaText).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        case .done:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(downloader.title.isEmpty ? "완료" : downloader.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                if let file = downloader.lastFile {
                    HStack(spacing: 10) {
                        Text(file.lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Finder에서 보기") { downloader.reveal(file) }.buttonStyle(.link).font(.system(size: 11))
                        Button("변환 목록에 추가") { converter.add(urls: [file]) }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if !downloader.duration.isEmpty { parts.append(downloader.duration) }
        if !downloader.resolution.isEmpty, downloader.quality != .audioMP3 { parts.append(downloader.resolution) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                downloader.chooseDirectory()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text(downloader.outputDirectory.lastPathComponent).font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("저장 폴더 바꾸기: " + downloader.outputDirectory.path)
            .disabled(downloader.isBusy)
            Spacer()
            if downloader.isBusy {
                Button("중단") { downloader.cancel() }.controlSize(.small)
            } else {
                Button {
                    downloader.start()
                } label: {
                    Label("다운로드", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!MediaDownloader.looksLikeURL(downloader.url))
            }
        }
    }
}
