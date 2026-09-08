import SwiftUI

/// 빠른 동작 › 리소스 잡아먹는 앱 정리
struct AppCleanupCard: View {
    @Bindable var cleaner: AppCleaner
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "xmark.app")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("리소스 잡아먹는 앱 정리")
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailingButton
            }
            switch cleaner.phase {
            case .idle:
                EmptyView()
            case .scanning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(Int(AppCleaner.scanSeconds))초 동안 CPU · 메모리 · 네트워크를 재는 중…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 40)
            case .ready, .quitting, .done:
                results
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private var subtitle: String {
        switch cleaner.phase {
        case .idle: return "백그라운드에서 CPU · 메모리 · 네트워크를 많이 쓰거나 창 없이 떠 있는 앱을 찾아 한 번에 종료해요."
        case .scanning: return "지금 실행 중인 앱을 살펴보고 있어요."
        case .ready: return cleaner.candidates.isEmpty ? "지금은 정리할 만한 앱이 없어요." : "제안 \(cleaner.suggestedCount)개 · 체크를 바꿔서 고른 뒤 종료하세요."
        case .quitting: return "종료 요청을 보냈어요. 잠시 기다리는 중…"
        case .done(let quit, let still):
            return still > 0 ? "\(quit)개 종료 · \(still)개는 아직 실행 중이에요 (저장 확인 중일 수 있어요)." : "\(quit)개 종료했어요."
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch cleaner.phase {
        case .idle:
            Button("검사") { cleaner.scan() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
        case .ready, .done:
            Button("다시 검사") { cleaner.scan() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .scanning, .quitting:
            EmptyView()
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !cleaner.candidates.isEmpty {
                VStack(spacing: 0) {
                    ForEach(cleaner.candidates) { app in
                        CandidateRow(app: app,
                                     toggle: { cleaner.toggleSelected(app.id) },
                                     protect: { cleaner.toggleProtected(app.id) })
                        if app.id != cleaner.candidates.last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chipFill(scheme).opacity(0.5)))
                HStack(spacing: 10) {
                    Toggle("강제 종료", isOn: $cleaner.forceQuit)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("켜면 저장 확인 없이 즉시 끝내요 (응답 없는 앱용)")
                    Spacer()
                    Button {
                        cleaner.quitSelected()
                    } label: {
                        Text(cleaner.selectedCount == 0 ? "종료할 앱을 고르세요" : "선택한 \(cleaner.selectedCount)개 종료")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(cleaner.selectedCount == 0 || cleaner.phase == .quitting)
                }
            }
            Text("지금 사용 중인 앱과 재생 중인 앱은 제안에서 빼요. 방패로 보호한 앱은 다음 검사에서도 제외돼요.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CandidateRow: View {
    let app: CleanupCandidate
    let toggle: () -> Void
    let protect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: app.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(app.selected ? Theme.accent : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .disabled(app.isProtected)
            ProcessIcon(bundlePath: app.bundlePath, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Format.memory(app.memoryBytes))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(app.memoryBytes >= 600 << 20 ? Color.orange : Color.secondary)
            Button(action: protect) {
                Image(systemName: app.isProtected ? "shield.fill" : "shield")
                    .font(.system(size: 12))
                    .foregroundStyle(app.isProtected ? Theme.accent : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(app.isProtected ? "보호 해제" : "보호: 정리 제안에서 항상 제외")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .opacity(app.isProtected ? 0.6 : 1)
    }

    private var detail: String {
        var parts = app.reasons
        if app.cpuPercent >= 1, !parts.contains(where: { $0.hasPrefix("CPU") }) { parts.append("CPU \(Int(app.cpuPercent.rounded()))%") }
        if app.windowCount > 0 { parts.append("창 \(app.windowCount)개") }
        if app.memoryBytes >= 600 << 20 { parts.append("메모리 많이 씀") }
        return parts.joined(separator: " · ")
    }
}
