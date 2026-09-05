import SwiftUI

struct KeepAwakeView: View {
    @Bindable var awake: KeepAwake
    @State private var showOptions = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                mainCard
                if awake.isActive { statusCard }
                infoText
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .onAppear { awake.refreshLidState() }
    }

    private var header: some View {
        HStack {
            Text("절전 방지")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if awake.isActive {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("켜짐").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.15)))
            }
        }
        .padding(.horizontal, 2)
    }

    private var mainCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac이 잠들지 않게 유지").font(.system(size: 14, weight: .semibold))
                    Text(awake.isActive ? "켜져 있는 동안 자동 잠자기를 막습니다." : "일반적인 에너지 절약 설정을 따릅니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { awake.isActive }, set: { awake.setActive($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().padding(.horizontal, 14)

            HStack {
                Text("지속 시간").font(.system(size: 13))
                Spacer()
                Picker("", selection: Binding(get: { awake.duration }, set: { awake.setDuration($0) })) {
                    ForEach(AwakeDuration.allCases) { d in
                        Text(d.title).tag(d)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 96)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            optionsSection

            Divider().padding(.horizontal, 14)

            lidRow
        }
        .card()
    }

    private var optionsSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showOptions.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showOptions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("옵션").font(.system(size: 13))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showOptions {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("화면도 켜 둠").font(.system(size: 13))
                        Text("끄면 화면은 꺼지고 Mac만 깨어 있어요.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { awake.keepDisplayOn }, set: { awake.setKeepDisplayOn($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .padding(.leading, 16)
            }
        }
    }

    private var lidRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("덮개를 닫아도 계속 유지").font(.system(size: 14, weight: .semibold))
                Text(awake.lidError ?? "전환할 때 관리자 암호를 묻습니다. 켜 두면 재시동 후에도 유지되니 끄는 것도 잊지 마세요.")
                    .font(.system(size: 11))
                    .foregroundStyle(awake.lidError == nil ? Color.secondary : Color.red)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { awake.lidSleepDisabled }, set: { awake.setLidSleepDisabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(awake.remainingText ?? "").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                if let started = awake.startedAt {
                    Text("시작 " + started.formatted(date: .omitted, time: .shortened) + (awake.keepDisplayOn ? " · 화면 켜 둠" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("끄기") { awake.setActive(false) }
                .controlSize(.small)
        }
        .padding(12)
        .card()
    }

    private var infoText: some View {
        Text("ATFM을 종료하면 절전 방지도 함께 풀립니다.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
    }
}
