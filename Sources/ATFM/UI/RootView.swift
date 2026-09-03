import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case clipboard
    case settings

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .settings: return "gearshape"
        }
    }

    var title: String {
        switch self {
        case .clipboard: return "클립보드"
        case .settings: return "설정"
        }
    }
}

struct RootView: View {
    @Bindable var viewModel: ClipboardViewModel
    var quit: () -> Void
    @State private var tab: AppTab = .clipboard

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 22)
                .padding(.bottom, 16)

            TabBar(selection: $tab)
                .padding(.horizontal, 20)

            ZStack {
                switch tab {
                case .clipboard:
                    ClipboardView(vm: viewModel)
                case .settings:
                    SettingsView(vm: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 14)

            HStack(spacing: 12) {
                BottomButton(
                    title: tab == .settings ? "클립보드" : "설정",
                    icon: tab == .settings ? "doc.on.clipboard" : "gearshape"
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        tab = tab == .settings ? .clipboard : .settings
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
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 17, weight: .medium))
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
