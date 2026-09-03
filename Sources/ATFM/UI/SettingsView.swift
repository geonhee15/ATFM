import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var vm: ClipboardViewModel
    @AppStorage(SettingsKey.maxItems) private var maxItems = 2000
    @AppStorage(SettingsKey.moveDuplicatesToTop) private var moveDuplicatesToTop = true
    @AppStorage(SettingsKey.captureImages) private var captureImages = true
    @AppStorage(SettingsKey.captureFiles) private var captureFiles = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("기록")
                historyCard
                sectionTitle("일반")
                generalCard
                sectionTitle("정보")
                infoCard
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .onChange(of: maxItems) { _, _ in vm.trimToLimit() }
        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
    }

    // MARK: Cards

    private var historyCard: some View {
        VStack(spacing: 0) {
            maxItemsRow
            rowDivider
            toggleRow("같은 내용은 맨 위로", "이미 있던 내용을 다시 복사하면 시간만 갱신", $moveDuplicatesToTop)
            rowDivider
            toggleRow("이미지 저장", "복사한 이미지도 기록에 남깁니다", $captureImages)
            rowDivider
            toggleRow("파일 복사 저장", "Finder에서 복사한 파일 경로를 기록", $captureFiles)
        }
        .card()
    }

    private var generalCard: some View {
        VStack(spacing: 0) {
            launchAtLoginRow
            rowDivider
            dataFolderRow
        }
        .card()
    }

    private var infoCard: some View {
        SettingsRow(title: "ATFM", subtitle: "Additional Things For Mac · v\(appVersion)") {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: Rows

    private var maxItemsRow: some View {
        SettingsRow(title: "최대 보관 개수", subtitle: "넘치면 오래된 항목부터 지워집니다") {
            maxItemsPicker
        }
    }

    private static let maxItemOptions: [Int] = [500, 1000, 2000, 5000, 10000]

    private var maxItemsPicker: some View {
        Picker("", selection: $maxItems) {
            ForEach(Self.maxItemOptions, id: \.self) { (n: Int) in
                Text(n.formatted() + "개").tag(n)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 104)
    }

    private var launchAtLoginRow: some View {
        SettingsRow(
            title: "로그인 시 자동 실행",
            subtitle: launchError ?? "메뉴 막대에 조용히 대기합니다",
            subtitleIsError: launchError != nil
        ) {
            switchToggle($launchAtLogin)
        }
    }

    private var dataFolderRow: some View {
        SettingsRow(title: "데이터 폴더", subtitle: dataSummary) {
            Button("열기") {
                NSWorkspace.shared.activateFileViewerSelecting([vm.store.databaseURL])
            }
            .controlSize(.small)
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            switchToggle(binding)
        }
    }

    private func switchToggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private var rowDivider: some View {
        Divider().padding(.horizontal, 12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    // MARK: Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var dataSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: vm.store.databaseSizeBytes, countStyle: .file)
        return "\(vm.items.count)개 항목 · \(size)"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let current = SMAppService.mainApp.status == .enabled
        guard enabled != current else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "설정 실패: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var subtitleIsError = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleIsError ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
