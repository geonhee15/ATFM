import AppKit
import Observation

/// Cross-cutting UI state: which tab is showing and whether the bubble is on screen.
/// Monitors only sample while their tab is actually visible.
@MainActor
@Observable
final class AppState {
    var tab: AppTab = .clipboard
    var isBubbleVisible = false
    private(set) var lastContentTab: AppTab = .clipboard
    private(set) var appearanceMode: AppearanceMode

    @ObservationIgnored var systemMonitor: SystemMonitor?
    @ObservationIgnored var networkMonitor: NetworkMonitor?
    @ObservationIgnored var quickActions: QuickActions?
    @ObservationIgnored var applyAppearance: ((AppearanceMode) -> Void)?
    private static let appearanceKey = "appearanceMode"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? ""
        appearanceMode = AppearanceMode(rawValue: stored) ?? .system
    }

    func setAppearance(_ mode: AppearanceMode) {
        appearanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.appearanceKey)
        applyAppearance?(mode)
    }

    func select(_ newTab: AppTab) {
        tab = newTab
        if newTab != .settings { lastContentTab = newTab }
        updateMonitors()
    }

    func setBubbleVisible(_ visible: Bool) {
        isBubbleVisible = visible
        updateMonitors()
    }

    func updateMonitors() {
        systemMonitor?.setActive(isBubbleVisible && tab == .system)
        networkMonitor?.setActive(isBubbleVisible && tab == .network)
        if isBubbleVisible && tab == .actions { quickActions?.refresh() }
    }
}
