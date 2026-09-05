import SwiftUI

struct ClapLockView: View {
    var clap: ClapLock
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                mainCard
                optionsCard
                if let notice = clap.lastNotice { noticeRow(notice) }
                if let error = clap.lastError { errorRow(error) }
                Text("Security-Protocol-1의 박수 감지 알고리즘을 오디오 전용으로 옮겼어요. 짧고 크고 넓은 대역의 소리 두 번이 0.12~1초 간격으로, 앞뒤가 조용할 때만 인정합니다. 키보드 연타나 말소리는 걸러져요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .onAppear { clap.refreshSP1Status() }
    }

    private var header: some View {
        HStack {
            Text("Security Protocol 1")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("박수 잠금")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.chipFill(scheme)))
            Spacer()
            statusChip
        }
        .padding(.horizontal, 2)
    }

    private var statusChip: some View {
        let color: Color = !clap.isEnabled ? .secondary : (clap.isListening ? (clap.awaitingSecond ? .orange : .green) : .orange)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(clap.statusText).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var mainCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "hands.clap.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("박수 두 번 → \(clap.actionSummary)").font(.system(size: 14, weight: .semibold))
                    Text("탁-탁! 하고 치면 바로 실행돼요. 마이크는 켜져 있는 동안만 듣습니다.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { clap.isEnabled }, set: { clap.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if clap.isEnabled {
                Divider().padding(.horizontal, 14)
                meter
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .card()
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("마이크 레벨").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "피크 %.2f · 바닥 %.3f", clap.level, clap.noiseFloor))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                let threshold = max(clap.sensitivity.thresholds.minPeak, clap.noiseFloor * clap.sensitivity.thresholds.overFloor)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(clap.level >= threshold ? Color.orange : Theme.accent)
                        .frame(width: geo.size.width * CGFloat(min(1, clap.level)))
                    Rectangle()
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat(min(1, threshold)))
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.08), value: clap.level)
            HStack {
                Text("빨간 선을 넘는 짧은 소리가 박수 후보예요").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if clap.detectionCount > 0, let last = clap.lastDetectedAt {
                    Text("감지 \(clap.detectionCount)회 · 마지막 " + last.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var sp1Subtitle: String {
        guard clap.sp1Installed else { return "Security-Protocol-1 프로젝트를 찾지 못했어요" }
        return clap.sp1Running ? "실행 중 · 박수 시 셰이드 → UNLOCK → 제스처 인증" : "꺼져 있음 · 박수 시 자동으로 실행한 뒤 잠가요"
    }

    private var optionsCard: some View {
        VStack(spacing: 0) {
            optionRow("Security Protocol 1 제스처 잠금", sp1Subtitle) {
                HStack(spacing: 8) {
                    if clap.sp1Installed, !clap.sp1Running {
                        Button("실행") { clap.launchSP1() }.controlSize(.small)
                    }
                    Toggle("", isOn: Binding(get: { clap.useSP1 }, set: { clap.setUseSP1($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!clap.sp1Installed)
                }
            }
            Divider().padding(.horizontal, 12)
            optionRow("잠금 화면 스타일", "심플은 그래프·효과를 빼고 애플식으로. 색은 테마(설정)를 따라요") {
                let _ = clap.sp1StyleVersion
                Picker("", selection: Binding(get: { clap.sp1Style }, set: { clap.setSP1Style($0) })) {
                    ForEach(SP1LockStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 170)
                .disabled(!clap.sp1Installed)
            }
            Divider().padding(.horizontal, 12)
            optionRow("추가 동작", clap.useSP1 ? "SP1 잠금에 이어서 실행 (없음이면 SP1만)" : "SP1 없이 이 동작만 실행") {
                Picker("", selection: Binding(get: { clap.extra }, set: { clap.setExtra($0) })) {
                    ForEach(ClapExtraAction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 130)
            }
            if !clap.useSP1, clap.extra == .none {
                Text("SP1 잠금과 추가 동작이 둘 다 꺼져 있어서 박수를 쳐도 아무 일도 안 일어나요.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider().padding(.horizontal, 12)
            optionRow("민감도", "둔감할수록 크고 또렷한 박수만 인정") {
                Picker("", selection: Binding(get: { clap.sensitivity }, set: { clap.setSensitivity($0) })) {
                    ForEach(ClapSensitivity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
            }
            Divider().padding(.horizontal, 12)
            optionRow("테스트 모드", "잠그지 않고 감지 여부만 알려줘요") {
                Toggle("", isOn: Binding(get: { clap.testMode }, set: { clap.setTestMode($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if clap.permission == .denied || clap.permission == .restricted {
                Divider().padding(.horizontal, 12)
                optionRow("마이크 권한", "시스템 설정에서 ATFM을 허용해 주세요") {
                    Button("설정 열기") { clap.openMicrophoneSettings() }.controlSize(.small)
                }
            }
        }
        .card()
    }

    private func optionRow<Control: View>(_ title: String, _ subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hands.clap.fill").foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .card(radius: 10)
    }

    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(text).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .card(radius: 10)
    }
}
