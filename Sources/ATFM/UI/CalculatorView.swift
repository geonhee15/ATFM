import SwiftUI

struct CalculatorView: View {
    @Bindable var calc: CalculatorModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    private static let keys: [[String]] = [
        ["C", "(", ")", "⌫"],
        ["7", "8", "9", "÷"],
        ["4", "5", "6", "×"],
        ["1", "2", "3", "−"],
        ["0", ".", "%", "+"],
        ["√", "^", "π", "="],
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                display
                keypad
                if !calc.history.isEmpty { historyCard }
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
    }

    private var header: some View {
        HStack {
            Text("계산기")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $calc.degrees) {
                Text("도").tag(true)
                Text("라디안").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 110)
        }
        .padding(.horizontal, 2)
    }

    private var display: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("12*3+4^2, sqrt(2), sin(30), 5!, 15%", text: $calc.input)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { calc.commit() }
            HStack(alignment: .firstTextBaseline) {
                if let error = calc.liveError, !calc.input.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let result = calc.liveResult {
                    Text("= \(result)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                } else if calc.input.isEmpty {
                    Text("Enter로 기록 · ans = 직전 결과")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    calc.copyResult()
                } label: {
                    Image(systemName: calc.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(calc.copied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(calc.liveResult == nil && calc.history.isEmpty)
                .help("결과 복사")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private var keypad: some View {
        VStack(spacing: 6) {
            ForEach(Array(Self.keys.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in
                        Button { tap(key) } label: {
                            Text(key)
                                .font(.system(size: 15, weight: key == "=" ? .bold : .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(background(for: key))
                                )
                                .foregroundStyle(key == "=" ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .card()
    }

    private func background(for key: String) -> Color {
        switch key {
        case "=": return Theme.accent
        case "÷", "×", "−", "+", "^", "√", "%", "π": return Theme.accent.opacity(0.14)
        case "C", "⌫", "(", ")": return Theme.chipFill(scheme)
        default: return scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.7)
        }
    }

    private func tap(_ key: String) {
        switch key {
        case "C": calc.clear()
        case "⌫": calc.backspace()
        case "=": calc.commit()
        case "√": calc.insert("√")
        default: calc.insert(key)
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("기록")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("지우기") { calc.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ForEach(calc.history.prefix(8)) { entry in
                HStack(spacing: 8) {
                    Text(entry.expression)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    Text("= \(entry.result)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { calc.useEntry(entry, expression: false) }
                .contextMenu {
                    Button("결과 사용") { calc.useEntry(entry, expression: false) }
                    Button("식 다시 사용") { calc.useEntry(entry, expression: true) }
                }
                .help("클릭: 결과를 입력에 넣기 · 우클릭: 식 다시 사용")
            }
            Spacer().frame(height: 6)
        }
        .card()
    }
}
