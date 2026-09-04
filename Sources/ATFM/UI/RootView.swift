import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case clipboard
    case checklist
    case awake
    case system
    case network
    case actions
    case ai
    case settings

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .checklist: return "checklist"
        case .awake: return "moon.zzz"
        case .system: return "cpu"
        case .network: return "network"
        case .actions: return "bolt"
        case .ai: return "bubble.left.and.text.bubble.right"
        case .settings: return "gearshape"
        }
    }

    var title: String {
        switch self {
        case .clipboard: return "클립보드"
        case .checklist: return "체크리스트"
        case .awake: return "절전 방지"
        case .system: return "시스템"
        case .network: return "네트워크"
        case .actions: return "빠른 동작"
        case .ai: return "간편 AI"
        case .settings: return "설정"
        }
    }
}

struct RootView: View {
    @Bindable var appState: AppState
    @Bindable var viewModel: ClipboardViewModel
    var systemMonitor: SystemMonitor
    var networkMonitor: NetworkMonitor
    var speedTester: SpeedTester
    var quickActions: QuickActions
    var checklist: ChecklistStore
    var keepAwake: KeepAwake
    var gemini: GeminiChat
    var quit: () -> Void

    private var tab: Binding<AppTab> {
        Binding(get: { appState.tab }, set: { appState.select($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 22)
                .padding(.bottom, 16)

            TabBar(selection: tab)
                .padding(.horizontal, 20)

            ZStack {
                switch appState.tab {
                case .clipboard:
                    ClipboardView(vm: viewModel)
                case .checklist:
                    ChecklistView(store: checklist)
                case .awake:
                    KeepAwakeView(awake: keepAwake)
                case .system:
                    SystemView(monitor: systemMonitor)
                case .network:
                    NetworkView(monitor: networkMonitor, tester: speedTester)
                case .actions:
                    QuickActionsView(appState: appState, quick: quickActions)
                case .ai:
                    GeminiChatView(chat: gemini)
                case .settings:
                    SettingsView(vm: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 14)

            HStack(spacing: 12) {
                BottomButton(
                    title: appState.tab == .settings ? appState.lastContentTab.title : "설정",
                    icon: appState.tab == .settings ? appState.lastContentTab.icon : "gearshape"
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        appState.select(appState.tab == .settings ? appState.lastContentTab : .settings)
                    }
                }
                BottomButton(title: "종료", icon: "power", action: quit)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selection == tab ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(4)
        .card(radius: 14)
    }
}

struct BottomButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(hovering ? Theme.hoverFill(scheme) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
        .onHover { hovering = $0 }
    }
}
