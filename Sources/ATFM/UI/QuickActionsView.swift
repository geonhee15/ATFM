import SwiftUI

struct QuickActionsView: View {
    @Bindable var appState: AppState
    @Bindable var quick: QuickActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                appearanceRow
                keyboardRow
                lockRow
                screenSaverRow
                displayRow
                trashRow
                ejectRow
                hiddenFilesRow
                desktopRow
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
    }

    private var header: some View {
        HStack {
            Text("빠른 동작")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                quick.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("상태 새로고침")
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    // MARK: Rows

    private var appearanceRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ATFM 다크 모드")
                        .font(.system(size: 14, weight: .semibold))
                    Text("이 창의 화면 모드만 바꿉니다. 시스템 설정은 그대로예요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Picker("", selection: appearanceBinding) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.leading, 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(get: { appState.appearanceMode }, set: { appState.setAppearance($0) })
    }

    private var keyboardRow: some View {
        ActionRow(icon: "keyboard.fill", title: "키보드 백라이트",
                  subtitle: quick.keyboardBacklightAvailable ? "키보드 백라이트를 켜거나 끕니다." : "이 Mac에서는 제어할 수 없어요.",
                  status: status(for: "kb")) {
            Toggle("", isOn: Binding(get: { quick.keyboardBacklightOn }, set: { quick.setKeyboardBacklight($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!quick.keyboardBacklightAvailable)
        }
    }

    private var lockRow: some View {
        ActionRow(icon: "lock.fill", title: "화면 잠금",
                  subtitle: "바로 잠금 화면으로 가서 암호를 요구합니다.",
                  status: status(for: "lock"), action: { quick.lockScreen() }) {
            chevron
        }
    }

    private var screenSaverRow: some View {
        ActionRow(icon: "sparkles.tv.fill", title: "화면 보호기 시작",
                  subtitle: "설정된 화면 보호기를 바로 띄웁니다.",
                  action: { quick.startScreenSaver() }) {
            chevron
        }
    }

    private var displayRow: some View {
        ActionRow(icon: "display", title: "디스플레이 끄기",
                  subtitle: "화면만 끕니다. Mac은 계속 동작해요.",
                  status: status(for: "display"), action: { quick.sleepDisplay() }) {
            chevron
        }
    }

    private var trashRow: some View {
        ActionRow(icon: "trash.fill", title: "휴지통 비우기",
                  subtitle: trashSubtitle,
                  status: status(for: "trash"),
                  action: quick.confirmEmptyTrash ? nil : { quick.confirmEmptyTrash = true }) {
            if quick.confirmEmptyTrash {
                HStack(spacing: 6) {
                    Button("취소") { quick.confirmEmptyTrash = false }
                    Button(role: .destructive) { quick.emptyTrash() } label: { Text("비우기") }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                .controlSize(.small)
            } else {
                chevron
            }
        }
    }

    private var trashSubtitle: String {
        if quick.confirmEmptyTrash { return "정말 비울까요? 되돌릴 수 없어요." }
        if let count = quick.trashItemCount {
            return count == 0 ? "휴지통이 비어 있어요." : "항목 \(count)개를 완전히 지웁니다."
        }
        return "휴지통의 모든 항목을 제거합니다."
    }

    private var ejectRow: some View {
        ActionRow(icon: "eject.fill", title: "모든 디스크 추출",
                  subtitle: ejectSubtitle,
                  status: status(for: "eject"), action: { quick.ejectAll() }) {
            chevron
        }
    }

    private var ejectSubtitle: String {
        if quick.externalVolumes.isEmpty { return "연결된 외장 디스크가 없어요." }
        return "외장 디스크 \(quick.externalVolumes.count)개: " + quick.externalVolumes.joined(separator: ", ")
    }

    private var hiddenFilesRow: some View {
        ActionRow(icon: "eye.fill", title: "숨겨진 파일 보기",
                  subtitle: "적용을 위해 Finder가 다시 시작됩니다.",
                  status: status(for: "hidden")) {
            Toggle("", isOn: Binding(get: { quick.showHiddenFiles }, set: { quick.setShowHiddenFiles($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var desktopRow: some View {
        ActionRow(icon: "menubar.dock.rectangle", title: "데스크탑 아이콘 가리기",
                  subtitle: "바탕화면 아이콘을 숨깁니다. Finder가 다시 시작됩니다.",
                  status: status(for: "desktop")) {
            Toggle("", isOn: Binding(get: { quick.desktopIconsHidden }, set: { quick.setDesktopIconsHidden($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func status(for id: String) -> QuickActions.Status? {
        guard let status = quick.status, status.id == id else { return nil }
        return status
    }
}

struct ActionRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var status: QuickActions.Status?
    var action: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let status {
                    Text(status.text)
                        .font(.system(size: 11))
                        .foregroundStyle(status.isError ? Color.red : Color.green)
                } else if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(hovering && action != nil ? Theme.hoverFill(scheme) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .onHover { hovering = $0 }
        .card()
    }
}
