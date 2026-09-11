import SwiftUI

struct TimersView: View {
    @Bindable var timers: TimerCenter
    @AppStorage("timersSection") private var section = "timer"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if section == "stopwatch" { stopwatch } else { countdown }
        }
        .padding(.horizontal, 20)
    }

    private var header: some View {
        HStack {
            Text("타이머")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $section) {
                Text("스탑워치").tag("stopwatch")
                Text("타이머").tag("timer")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 150)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Stopwatch

    private var stopwatch: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: timers.stopwatchRunning ? 0.03 : 60)) { context in
                    Text(TimerCenter.format(timers.stopwatchElapsed(at: context.date), showFraction: true))
                        .font(.system(size: 40, weight: .light, design: .rounded))
                        .monospacedDigit()
                }
                HStack(spacing: 10) {
                    Button(timers.stopwatchRunning ? "랩" : "재설정") {
                        if timers.stopwatchRunning { timers.stopwatchLap() } else { timers.stopwatchReset() }
                    }
                    .controlSize(.large)
                    .disabled(!timers.stopwatchRunning && timers.stopwatchElapsed() == 0)
                    Button(timers.stopwatchRunning ? "정지" : (timers.stopwatchElapsed() > 0 ? "계속" : "시작")) {
                        timers.stopwatchToggle()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(timers.stopwatchRunning ? .red : .green)
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .card()
            if !timers.laps.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(timers.laps.enumerated().reversed()), id: \.offset) { index, total in
                            let previous = index == 0 ? 0 : timers.laps[index - 1]
                            HStack {
                                Text("랩 \(index + 1)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                Spacer()
                                Text(TimerCenter.format(total - previous, showFraction: true))
                                    .font(.system(size: 13, design: .rounded)).monospacedDigit()
                                Text(TimerCenter.format(total, showFraction: true))
                                    .font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(.tertiary)
                                    .frame(width: 72, alignment: .trailing)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            if index != 0 { Divider().padding(.leading, 14) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .card()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Countdown

    private var countdown: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 12) {
                    TimelineView(.periodic(from: .now, by: timers.timerRunning ? 0.25 : 60)) { context in
                        Text(TimerCenter.format(timers.remaining(at: context.date), showFraction: false))
                            .font(.system(size: 44, weight: .light, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(timers.timerFinished ? Color.red : Color.primary)
                    }
                    if timers.timerFinished {
                        Text("타이머 종료!")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 10) {
                        Button("재설정") { timers.resetTimer() }
                            .controlSize(.large)
                            .disabled(!timers.timerRunning && !timers.timerPaused && !timers.timerFinished)
                        Button(primaryTitle) {
                            if timers.timerRunning { timers.pauseTimer() } else { timers.startTimer() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(timers.timerRunning ? .orange : .green)
                        .controlSize(.large)
                        .disabled(timers.timerFinished)
                        Button("+1분") { timers.addMinute() }
                            .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .card()
                if !timers.timerRunning && !timers.timerPaused {
                    durationCard
                }
                ActionRow(icon: "menubar.rectangle", title: "메뉴 막대에 남은 시간 표시",
                          subtitle: "타이머가 돌 때 ATFM 아이콘 옆에 남은 시간이 보여요.") {
                    Toggle("", isOn: $timers.showInMenuBar)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if timers.notificationsAllowed == false {
                    Text("알림이 꺼져 있어요. 시스템 설정 › 알림에서 ATFM을 허용하면 끝날 때 알림도 와요. (소리와 상단 팝업은 그대로 동작)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var primaryTitle: String {
        if timers.timerRunning { return "일시정지" }
        if timers.timerPaused { return "계속" }
        return "시작"
    }

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("시간 설정")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                ForEach(TimerCenter.presets, id: \.self) { minutes in
                    let seconds = TimeInterval(minutes * 60)
                    Button {
                        timers.setDuration(seconds)
                    } label: {
                        Text(minutes >= 60 ? "\(minutes / 60)시간" : "\(minutes)분")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(timers.duration == seconds ? Theme.accent.opacity(0.18) : Theme.chipFill(scheme))
                            )
                            .foregroundStyle(timers.duration == seconds ? Theme.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                unitStepper("시간", value: Int(timers.duration) / 3600, range: 0...23) { h in
                    timers.setDuration(TimeInterval(h * 3600 + (Int(timers.duration) % 3600)))
                }
                unitStepper("분", value: (Int(timers.duration) % 3600) / 60, range: 0...59) { m in
                    timers.setDuration(TimeInterval((Int(timers.duration) / 3600) * 3600 + m * 60 + Int(timers.duration) % 60))
                }
                unitStepper("초", value: Int(timers.duration) % 60, range: 0...59) { s in
                    timers.setDuration(TimeInterval((Int(timers.duration) / 60) * 60 + s))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private func unitStepper(_ label: String, value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text("\(value)").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().frame(minWidth: 22, alignment: .trailing)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Stepper("", value: Binding(get: { value }, set: { set(min(max($0, range.lowerBound), range.upperBound)) }), in: range)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}
