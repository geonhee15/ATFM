import SwiftUI

struct ScreenToolsView: View {
    @Bindable var tools: ScreenTools
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                if !tools.hasScreenAccess { permissionCard }
                textRow
                colorRow
                hotkeyCard
                statusRow
                if !tools.records.isEmpty { recentCard }
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .onAppear { tools.refreshAccess() }
        .onDisappear { tools.hotkeys.cancelRecording() }
    }

    private var hotkeys: ToolHotkeys { tools.hotkeys }

    private var hotkeyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("단축키")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !hotkeys.allDefault {
                    Button("모두 기본값으로") { hotkeys.resetAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ForEach(ToolHotkeys.Action.allCases) { action in
                HotkeyRow(action: action, hotkeys: hotkeys)
                if action != ToolHotkeys.Action.allCases.last {
                    Divider().padding(.leading, 14)
                }
            }
            Text(hotkeys.message ?? "조합을 클릭한 뒤 새 키를 누르세요 · Esc 취소 · 다른 앱을 쓰는 중에도 동작해요")
                .font(.system(size: 10))
                .foregroundStyle(hotkeys.message == nil ? Color.secondary.opacity(0.8) : Color.red)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .card()
    }

    private var header: some View {
        HStack {
            Text("빠른 툴")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("결과는 화면 위쪽에 잠깐 표시되고 클립보드에 복사돼요")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    private var textRow: some View {
        ActionRow(icon: "text.viewfinder", title: "화면 텍스트 복사",
                  subtitle: "영역을 드래그하면 그 안의 글자를 읽어 복사해요 (한국어·영어).") {
            Button {
                tools.captureText()
            } label: {
                Label("영역 선택", systemImage: "plus.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.small)
        }
    }

    private var colorRow: some View {
        ActionRow(icon: "eyedropper.halffull", title: "화면 색상 추출",
                  subtitle: "스포이드로 원하는 지점을 클릭하면 HEX 코드를 복사해요.") {
            Button {
                tools.pickColor()
            } label: {
                Label("스포이드", systemImage: "eyedropper")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.small)
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("화면 기록 권한이 필요해요")
                        .font(.system(size: 14, weight: .semibold))
                    Text("텍스트 복사는 화면을 캡처해서 읽어요. 시스템 설정 › 개인정보 보호 › 화면 기록에서 ATFM을 켠 뒤 다시 실행해 주세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("권한 요청") { tools.requestScreenAccess() }
                Button("설정 열기") { tools.openScreenRecordingSettings() }
                Button("ATFM 다시 실행") { tools.relaunch() }
            }
            .controlSize(.small)
            .padding(.leading, 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    @ViewBuilder
    private var statusRow: some View {
        switch tools.status {
        case .idle:
            EmptyView()
        case .selecting:
            statusText("영역을 드래그하세요 · Esc로 취소", color: .secondary)
        case .recognizing:
            statusText("텍스트 인식 중…", color: .secondary)
        case .picking:
            statusText("스포이드로 색을 클릭하세요 · Esc로 취소", color: .secondary)
        case .done(let message):
            statusText(message, color: .green)
        case .failed(let message):
            statusText(message, color: .red)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("최근")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ForEach(tools.records) { record in
                RecordRow(record: record) { tools.copy(record: record) } remove: { tools.remove(record: record) }
                if record.id != tools.records.last?.id {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .padding(.bottom, 4)
        .card()
    }
}

private struct RecordRow: View {
    let record: ToolRecord
    let copy: () -> Void
    let remove: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            switch record.kind {
            case .text(let text):
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .lineLimit(2)
            case .color(let color, let hex):
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                    .frame(width: 18)
                Text(hex)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            Spacer(minLength: 8)
            Text(Self.time.string(from: record.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("목록에서 지우기")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(hovering ? Theme.hoverFill(scheme) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .onHover { hovering = $0 }
        .help("클릭하면 다시 복사")
    }
}

private struct HotkeyRow: View {
    let action: ToolHotkeys.Action
    let hotkeys: ToolHotkeys

    @Environment(\.colorScheme) private var scheme

    private var recording: Bool { hotkeys.recording == action }

    var body: some View {
        HStack(spacing: 10) {
            Text(action.title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            if !hotkeys.isDefault(action) && !recording {
                Button {
                    hotkeys.reset(action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("기본값 \(action.defaultCombo.display)로 되돌리기")
            }
            Button {
                if recording { hotkeys.cancelRecording() } else { hotkeys.beginRecording(action) }
            } label: {
                Text(recording ? "키를 누르세요…" : hotkeys.combo(for: action).display)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(recording ? Theme.accent : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(recording ? Theme.accent.opacity(0.14) : Theme.chipFill(scheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(recording ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(recording ? "Esc로 취소" : "클릭해서 바꾸기")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
