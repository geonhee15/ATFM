import SwiftUI

struct AutoClickView: View {
    @Bindable var clicker: AutoClicker
    var hotkeys: ToolHotkeys
    @Environment(\.colorScheme) private var scheme
    @State private var intervalUnit = "ms"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                statusCard
                if !clicker.accessibilityTrusted { permissionCard }
                intervalCard
                clickCard
                positionCard
                repeatCard
                safetyCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .onAppear { clicker.refreshPermission(); intervalUnit = clicker.intervalMs >= 60_000 ? "분" : (clicker.intervalMs >= 1000 ? "초" : "ms") }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: "오토클릭")
            Spacer()
            Text(String(format: "%.1f회/초", clicker.clicksPerSecond)).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if clicker.isActive { clicker.stop() } else { clicker.startFromPanel() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: clicker.isActive ? "stop.fill" : "play.fill")
                        Text(startButtonTitle)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(clicker.isActive ? Color.red.opacity(0.85) : Theme.accent))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.system(size: 12, weight: .semibold))
                    Text(statusDetail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().padding(.horizontal, 14)
            HotkeyRow(action: .autoClick, hotkeys: hotkeys)
            if let message = hotkeys.message, hotkeys.recording == nil {
                Text(message).font(.system(size: 10.5)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
        .card()
    }

    private var startButtonTitle: String {
        switch clicker.phase {
        case .idle: return clicker.startDelay > 0 ? "\(clicker.startDelay)초 뒤 시작" : "시작"
        case .countdown: return "취소"
        case .running: return "정지"
        }
    }

    private var statusTitle: String {
        switch clicker.phase {
        case .idle: return "대기"
        case .countdown(let left): return "\(left)초 뒤 시작해요 — 클릭할 곳으로 마우스를 옮기세요"
        case .running: return "클릭 중 · \(clicker.clickCount)회" + (clicker.isDryRun ? " (연습)" : "")
        }
    }

    private var statusDetail: String {
        switch clicker.phase {
        case .running:
            let seconds = Int(clicker.elapsed)
            var parts = [String(format: "%d:%02d 경과", seconds / 60, seconds % 60)]
            if clicker.repeatMode == .count { parts.append("목표 \(clicker.repeatCount)회") }
            if clicker.repeatMode == .duration { parts.append("\(Int(clicker.durationSeconds))초 동안") }
            parts.append("단축키 · Esc로 정지")
            return parts.joined(separator: " · ")
        case .countdown:
            return "\(clicker.intervalText) 간격 · \(clicker.button.title) \(clicker.clickType.title) · \(clicker.positionMode == .fixed ? clicker.fixedPointText : "마우스 위치")"
        case .idle:
            if let reason = clicker.lastStopReason { return "마지막: \(clicker.clickCount)회 · \(reason)" }
            return "\(clicker.intervalText) 간격 · \(clicker.button.title) \(clicker.clickType.title) · \(clicker.positionMode.title)"
        }
    }

    private var permissionCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("손쉬운 사용 권한이 필요해요").font(.system(size: 12, weight: .semibold))
                Text("다른 앱에 클릭을 보내려면 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 ATFM을 켜 주세요").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(spacing: 4) {
                Button("권한 요청") { clicker.requestPermission() }.controlSize(.small)
                Button("설정 열기") { clicker.openAccessibilitySettings() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    // MARK: Interval

    private var intervalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("간격", systemImage: "metronome").font(.system(size: 12, weight: .semibold))
                Spacer()
                TextField("", value: intervalBinding, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 64).multilineTextAlignment(.trailing)
                    .disabled(clicker.isActive)
                Picker("", selection: $intervalUnit) {
                    Text("ms").tag("ms"); Text("초").tag("초"); Text("분").tag("분")
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
            HStack(spacing: 4) {
                ForEach(AutoClicker.presetsMs, id: \.self) { preset in
                    let selected = abs(clicker.intervalMs - preset) < 0.5
                    Button {
                        clicker.intervalMs = preset
                        intervalUnit = preset >= 1000 ? "초" : "ms"
                    } label: {
                        Text(presetTitle(preset))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(selected ? Theme.accent.opacity(0.18) : Theme.chipFill(scheme)))
                            .foregroundStyle(selected ? Theme.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Text("무작위").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                Slider(value: $clicker.jitterPercent, in: 0...50).controlSize(.small)
                Text("±\(Int(clicker.jitterPercent))%").font(.system(size: 10.5, weight: .medium, design: .rounded)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .help("간격을 조금씩 흔들어 사람이 누르는 것처럼")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: {
                switch intervalUnit {
                case "초": return clicker.intervalMs / 1000
                case "분": return clicker.intervalMs / 60_000
                default: return clicker.intervalMs
                }
            },
            set: { value in
                let ms: Double
                switch intervalUnit {
                case "초": ms = value * 1000
                case "분": ms = value * 60_000
                default: ms = value
                }
                clicker.intervalMs = min(3_600_000, max(5, ms))
            })
    }

    private func presetTitle(_ ms: Double) -> String {
        ms >= 1000 ? String(format: "%g초", ms / 1000) : "\(Int(ms))ms"
    }

    // MARK: Click

    private var clickCard: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "computermouse", title: "버튼", subtitle: nil) {
                Picker("", selection: $clicker.button) { ForEach(AutoClicker.MouseButton.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 170)
            }
            Divider().padding(.horizontal, 14)
            ActionRow(icon: "cursorarrow.click.2", title: "클릭", subtitle: "두 번 = 더블클릭") {
                Picker("", selection: $clicker.clickType) { ForEach(AutoClicker.ClickType.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 120)
            }
        }
        .card()
    }

    // MARK: Position

    private var positionCard: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "scope", title: "위치", subtitle: clicker.positionMode == .follow ? "포인터 자리" : "저장한 좌표") {
                Picker("", selection: $clicker.positionMode) { ForEach(AutoClicker.PositionMode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 176)
            }
            if clicker.positionMode == .fixed {
                Divider().padding(.horizontal, 14)
                HStack(spacing: 8) {
                    Text("X").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("", value: Binding(get: { Int(clicker.fixedPoint.x) }, set: { clicker.fixedPoint.x = CGFloat($0) }), format: .number)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 64)
                    Text("Y").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("", value: Binding(get: { Int(clicker.fixedPoint.y) }, set: { clicker.fixedPoint.y = CGFloat($0) }), format: .number)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 64)
                    Spacer()
                    Button {
                        clicker.captureFixedPoint()
                    } label: {
                        if let left = clicker.captureCountdown { Text("\(left)초 뒤 저장…") } else { Label("3초 뒤 마우스 위치 저장", systemImage: "scope") }
                    }
                    .controlSize(.small)
                    .disabled(clicker.captureCountdown != nil)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .card()
    }

    // MARK: Repeat

    private var repeatCard: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "repeat", title: "반복", subtitle: nil) {
                Picker("", selection: $clicker.repeatMode) { ForEach(AutoClicker.RepeatMode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 190)
            }
            if clicker.repeatMode != .forever {
                Divider().padding(.horizontal, 14)
                HStack(spacing: 8) {
                    if clicker.repeatMode == .count {
                        Text("클릭 횟수").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("", value: $clicker.repeatCount, format: .number).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 70)
                        Stepper("", value: $clicker.repeatCount, in: 1...1_000_000, step: 10).labelsHidden().controlSize(.small)
                        Text("회").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("지속 시간").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("", value: $clicker.durationSeconds, format: .number).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 70)
                        Stepper("", value: $clicker.durationSeconds, in: 1...86_400, step: 5).labelsHidden().controlSize(.small)
                        Text("초").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .card()
    }

    // MARK: Safety

    private var safetyCard: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "timer", title: "버튼으로 시작할 때 대기", subtitle: "그 사이에 클릭할 창으로 옮겨요 · 단축키는 바로 시작") {
                HStack(spacing: 6) {
                    Text("\(clicker.startDelay)초").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    Stepper("", value: $clicker.startDelay, in: 0...10).labelsHidden().controlSize(.small)
                }
            }
            Divider().padding(.horizontal, 14)
            ActionRow(icon: "hand.raised", title: "마우스를 움직이면 정지", subtitle: "고정 위치 모드에서 24px 넘게 움직이면 멈춰요") {
                Toggle("", isOn: $clicker.stopOnMove).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Text("언제든 단축키(\(hotkeys.combo(for: .autoClick).display))나 Esc로 멈출 수 있어요. 게임·웹사이트 약관상 자동 입력이 금지된 곳에서는 쓰지 마세요.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .card()
    }
}
