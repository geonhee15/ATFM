import SwiftUI
import UniformTypeIdentifiers

struct AudioEditorView: View {
    @Bindable var editor: AudioEditor
    @Environment(\.colorScheme) private var scheme
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let source = editor.source {
                    sourceCard(source)
                    waveformCard(source)
                    speedCard
                    soundCard
                    exportCard(source)
                } else {
                    emptyCard
                }
                if let error = editor.loadError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { editor.handleDrop($0) }
        // Keep the keyboard on the transport (space = play/pause) instead of the first time field.
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .onChange(of: editor.source?.url) { _, _ in DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.08)))
                    .padding(.horizontal, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: "오디오 편집기")
            Spacer()
            Text("자르기 · 배속 · 볼륨 · 변환")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Empty / source

    private var emptyCard: some View {
        Button { editor.chooseFile() } label: {
            VStack(spacing: 8) {
                if editor.isLoading {
                    ProgressView().controlSize(.small)
                    Text("파일 여는 중…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "waveform.badge.plus").font(.system(size: 30, weight: .medium)).foregroundStyle(Theme.accent)
                    Text("오디오 파일을 끌어다 놓거나 눌러서 열기").font(.system(size: 13, weight: .semibold))
                    Text("MP3 · M4A · WAV · FLAC · OGG … 동영상을 넣으면 소리만 가져와요")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }

    private func sourceCard(_ source: AudioEditor.Source) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.14)))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(sourceDetail(source)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if editor.isLoading { ProgressView().controlSize(.small) }
            Button { editor.chooseFile() } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("다른 파일 열기")
            Button { editor.close() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("닫기")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .card()
    }

    private func sourceDetail(_ source: AudioEditor.Source) -> String {
        var parts = [AudioEditor.timeText(source.duration)]
        parts.append(String(format: "%.1fkHz", source.sampleRate / 1000))
        parts.append(source.channels == 1 ? "모노" : (source.channels == 2 ? "스테레오" : "\(source.channels)채널"))
        if !source.formatName.isEmpty { parts.append(source.formatName) }
        if source.fileSize > 0 { parts.append(Format.bytes(source.fileSize)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Waveform + trim

    private func waveformCard(_ source: AudioEditor.Source) -> some View {
        VStack(spacing: 8) {
            TrimWaveform(editor: editor, duration: source.duration)
                .frame(height: 74)
            HStack(spacing: 8) {
                Button { editor.togglePlay() } label: {
                    Image(systemName: editor.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .keyboardShortcut(.space, modifiers: [])
                Text(AudioEditor.timeText(editor.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Button { editor.loop.toggle() } label: {
                    Image(systemName: "repeat").font(.system(size: 11, weight: .semibold))
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(editor.loop ? Theme.accent.opacity(0.18) : Color.clear))
                        .foregroundStyle(editor.loop ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain).help("선택 구간 반복")
                Spacer()
                smallButton("여기부터") { editor.setTrimStart(editor.currentTime); editor.trimCommitted() }
                    .help("지금 위치를 시작점으로")
                smallButton("여기까지") { editor.setTrimEnd(editor.currentTime); editor.trimCommitted() }
                    .help("지금 위치를 끝점으로")
                if editor.isTrimmed { smallButton("전체") { editor.resetTrim() } }
            }
            HStack(spacing: 6) {
                Text("시작").font(.system(size: 10.5)).foregroundStyle(.secondary)
                TimeField(value: editor.settings.start) { editor.setTrimStart($0); editor.trimCommitted() }
                Text("끝").font(.system(size: 10.5)).foregroundStyle(.secondary)
                TimeField(value: editor.settings.end) { editor.setTrimEnd($0); editor.trimCommitted() }
                Spacer()
                Text("선택 \(AudioEditor.timeText(editor.settings.selectedDuration))")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.chipFill(scheme)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Speed

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("배속", systemImage: "speedometer").font(.system(size: 12, weight: .semibold))
                Text(String(format: "%.2fx", editor.settings.speed))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(abs(editor.settings.speed - 1) > 0.001 ? Theme.accent : Color.primary)
                Text("→ \(AudioEditor.timeText(editor.settings.outputDuration))")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Toggle("음정 유지", isOn: $editor.settings.keepPitch)
                    .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11)).fixedSize()
                    .help("끄면 테이프처럼 빠를수록 음이 높아져요")
            }
            Slider(value: stepped($editor.settings.speed, 0.05), in: AudioEditor.speedRange).controlSize(.small)
            HStack(spacing: 5) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { preset in
                    let selected = abs(editor.settings.speed - preset) < 0.001
                    Button { editor.settings.speed = preset } label: {
                        Text(preset == 1 ? "1x" : String(format: "%gx", preset))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(selected ? Theme.accent.opacity(0.18) : Theme.chipFill(scheme)))
                            .foregroundStyle(selected ? Theme.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    /// A slider binding that snaps to `step` without drawing tick marks.
    private func stepped(_ binding: Binding<Double>, _ step: Double) -> Binding<Double> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = ($0 / step).rounded() * step })
    }

    // MARK: Sound

    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("소리", systemImage: "speaker.wave.2").font(.system(size: 12, weight: .semibold))
                Spacer()
                if editor.hasEffects {
                    Button("효과 초기화") { editor.resetEffects() }
                        .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            sliderRow("볼륨", value: $editor.settings.gainDB, range: -20...20, step: 0.5,
                      text: String(format: "%+.1f dB", editor.settings.gainDB))
            sliderRow("페이드 인", value: $editor.settings.fadeIn, range: 0...10, step: 0.1,
                      text: String(format: "%.1f초", editor.settings.fadeIn))
            sliderRow("페이드 아웃", value: $editor.settings.fadeOut, range: 0...10, step: 0.1,
                      text: String(format: "%.1f초", editor.settings.fadeOut))
            HStack(spacing: 14) {
                Toggle("음량 자동 맞춤", isOn: $editor.settings.normalize).help("전체 음량을 표준 크기(−16 LUFS)로")
                Toggle("거꾸로", isOn: $editor.settings.reverse)
                Spacer()
            }
            .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
            Text("재생 버튼은 자르기·배속·볼륨을 바로 들려줘요. 페이드·음량 맞춤·거꾸로는 '결과 미리 듣기'로 확인해요.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Slider(value: stepped(value, step), in: range).controlSize(.small)
            Text(text).font(.system(size: 10.5, weight: .medium, design: .rounded)).monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }

    // MARK: Export

    private func exportCard(_ source: AudioEditor.Source) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("내보내기", systemImage: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $editor.format) {
                    ForEach(AudioExportFormat.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                if editor.format.isLossy {
                    Picker("", selection: $editor.bitrate) {
                        ForEach(AudioEditor.bitrates, id: \.self) { Text("\($0)k").tag($0) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $editor.location) {
                    Text("원본 폴더").tag(AudioEditor.Location.sameFolder)
                    Text("다운로드").tag(AudioEditor.Location.downloads)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
                Spacer()
                Text(resultSummary).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            if !editor.hasFFmpeg {
                Text("내보내기에는 ffmpeg가 필요해요. 터미널에서 brew install ffmpeg 를 실행한 뒤 ATFM을 다시 열어 주세요.")
                    .font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let progress = editor.exportProgress {
                HStack(spacing: 8) {
                    ProgressView(value: progress).controlSize(.small)
                    Text("\(Int(progress * 100))%").font(.system(size: 10.5, design: .monospaced)).frame(width: 34, alignment: .trailing)
                    Button("중단") { editor.cancelExport() }.controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button { editor.toggleResultPreview() } label: {
                        Label(previewTitle, systemImage: previewSymbol).font(.system(size: 11, weight: .medium))
                    }
                    .controlSize(.small)
                    .disabled(!editor.hasFFmpeg)
                    Spacer()
                    Button { editor.export() } label: {
                        Label("내보내기", systemImage: "arrow.down.to.line")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(editor.hasFFmpeg ? Theme.accent : Color.gray.opacity(0.4)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!editor.hasFFmpeg)
                }
            }
            if let error = editor.exportError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let output = editor.lastOutput {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                    Text(output.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Finder에서 보기") { editor.revealOutput() }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    private var resultSummary: String {
        var text = AudioEditor.timeText(editor.settings.outputDuration)
        if let bytes = editor.estimatedBytes { text += " · 약 " + Format.bytes(bytes) }
        return text
    }

    private var previewTitle: String {
        switch editor.resultPreview {
        case .idle: return "결과 미리 듣기"
        case .rendering(let progress): return "준비 중 \(Int(progress * 100))%"
        case .playing: return "미리 듣기 정지"
        }
    }

    private var previewSymbol: String {
        switch editor.resultPreview {
        case .idle: return "ear"
        case .rendering: return "hourglass"
        case .playing: return "stop.fill"
        }
    }
}

// MARK: - Waveform with trim handles

private struct TrimWaveform: View {
    @Bindable var editor: AudioEditor
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            let total = max(duration, 0.001)
            let startX = CGFloat(editor.settings.start / total) * width
            let endX = CGFloat(editor.settings.end / total) * width
            let playX = CGFloat(min(max(editor.currentTime, 0), total) / total) * width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let bars = editor.waveform
                    guard !bars.isEmpty else { return }
                    let step = size.width / CGFloat(bars.count)
                    for (index, value) in bars.enumerated() {
                        let x = CGFloat(index) * step
                        let h = max(1.5, CGFloat(value) * (size.height - 10))
                        let rect = CGRect(x: x, y: (size.height - h) / 2, width: max(0.8, step - 0.8), height: h)
                        let inside = x + step / 2 >= startX && x + step / 2 <= endX
                        context.fill(Path(roundedRect: rect, cornerRadius: 0.6),
                                     with: .color(inside ? Theme.accent.opacity(0.9) : Color.primary.opacity(0.2)))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim-wave")).onChanged { value in
                    editor.seek(to: Double(min(max(0, value.location.x), width) / width) * total)
                })
                // selection frame
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent.opacity(0.08)))
                    .frame(width: max(2, endX - startX), height: height)
                    .offset(x: startX)
                    .allowsHitTesting(false)
                // playhead
                Rectangle().fill(Color.red).frame(width: 1.5, height: height)
                    .offset(x: playX - 0.75)
                    .allowsHitTesting(false)
                handle(at: startX, height: height, leading: true) { x in
                    editor.setTrimStart(Double(x / width) * total)
                }
                handle(at: endX, height: height, leading: false) { x in
                    editor.setTrimEnd(Double(x / width) * total)
                }
            }
            .coordinateSpace(name: "trim-wave")
        }
    }

    private func handle(at x: CGFloat, height: CGFloat, leading: Bool, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 9, height: height)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 18))
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            .offset(x: x - (leading ? 9.5 : 9.5))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim-wave"))
                .onChanged { onDrag($0.location.x) }
                .onEnded { _ in editor.trimCommitted() })
            .help(leading ? "시작점" : "끝점")
    }
}

/// "m:ss.s" text field that commits on Return.
private struct TimeField: View {
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var shown = ""          // what we last put in the field; differs from `text` only while the user types
    @FocusState private var focused: Bool

    private func refresh() {
        shown = AudioEditor.timeText(value)
        text = shown
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 70)
            .focused($focused)
            .onSubmit {
                if let parsed = AudioEditor.parseTime(text) { commit(parsed) }
                refresh()
            }
            .onAppear { refresh() }
            .onChange(of: value) { _, _ in if !focused || text == shown { refresh() } }
            .onChange(of: focused) { _, isFocused in if !isFocused { refresh() } }
    }
}
