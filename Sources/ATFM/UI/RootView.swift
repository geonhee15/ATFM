import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case clipboard
    case checklist
    case awake
    case system
    case network
    case actions
    case convert
    case player
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
        case .convert: return "arrow.triangle.2.circlepath"
        case .player: return "music.note"
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
        case .convert: return "파일 변환"
        case .player: return "미니 플레이어"
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
    var converter: FileConverter
    var nowPlaying: NowPlayingMonitor
    var miniPlayer: MiniPlayerController
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
                case .convert:
                    ConvertView(converter: converter)
                case .player:
                    NowPlayingTabView(monitor: nowPlaying, controller: miniPlayer)
                case .ai:
                    GeminiChatView(chat: gemini)
                case .settings:
                    SettingsView(vm: viewModel, appState: appState)
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
        .overlay(alignment: .leading) { ResizeEdge(axis: .horizontal, edge: .leading, appState: appState) }
        .overlay(alignment: .trailing) { ResizeEdge(axis: .horizontal, edge: .trailing, appState: appState) }
        .overlay(alignment: .bottom) { ResizeEdge(axis: .vertical, edge: .bottom, appState: appState) }
        .overlay(alignment: .bottomTrailing) { ResizeGrip(appState: appState) }
    }
}

// MARK: - Resize handles (the bubble has no title bar, so we do it ourselves)

/// Tracks the mouse in screen coordinates so window moves during the drag don't distort the delta.
@MainActor
final class ResizeDragTracker {
    private var last: CGPoint?

    func step() -> CGSize {
        let mouse = NSEvent.mouseLocation
        defer { last = mouse }
        guard let last else { return .zero }
        return CGSize(width: mouse.x - last.x, height: mouse.y - last.y)   // screen coords: y grows upward
    }

    func end() { last = nil }
}

struct ResizeEdge: View {
    enum Edge { case leading, trailing, bottom }
    let axis: Axis
    let edge: Edge
    var appState: AppState
    @State private var tracker = ResizeDragTracker()

    var body: some View {
        Color.clear
            .frame(width: axis == .horizontal ? 6 : nil, height: axis == .vertical ? 6 : nil)
            .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
            .padding(axis == .vertical ? .horizontal : .vertical, 18)   // leave the corners to the grip / rounded corners
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in
                        let step = tracker.step()
                        var delta = BubbleResizeDelta()
                        switch edge {
                        case .leading: delta.left = step.width
                        case .trailing: delta.right = step.width
                        case .bottom: delta.bottom = -step.height
                        }
                        appState.resizeBubble?(delta)
                    }
                    .onEnded { _ in
                        tracker.end()
                        NSCursor.arrow.set()
                    }
            )
    }
}

struct ResizeGrip: View {
    var appState: AppState
    @State private var tracker = ResizeDragTracker()
    @State private var hovering = false

    var body: some View {
        ZStack {
            Path { path in
                for i in 0..<3 {
                    let offset = CGFloat(i) * 4
                    path.move(to: CGPoint(x: 12 - offset, y: 12))
                    path.addLine(to: CGPoint(x: 12, y: 12 - offset))
                }
            }
            .stroke(Color.secondary.opacity(hovering ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 12, height: 12)
        }
        .frame(width: 22, height: 22, alignment: .bottomTrailing)
        .padding(4)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                if #available(macOS 15.0, *) {
                    NSCursor.frameResize(position: .bottomRight, directions: .all).set()
                } else {
                    NSCursor.crosshair.set()
                }
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    let step = tracker.step()
                    appState.resizeBubble?(BubbleResizeDelta(right: step.width, bottom: -step.height))
                }
                .onEnded { _ in
                    tracker.end()
                    NSCursor.arrow.set()
                }
        )
        .onTapGesture(count: 2) { appState.resetBubbleSize?() }
        .help("드래그해서 크기 조절 · 더블클릭으로 기본 크기")
    }
}

struct TabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 1) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 14, weight: .medium))
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
