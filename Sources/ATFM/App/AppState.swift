import Observation

/// Cross-cutting UI state: which tab is showing and whether the bubble is on screen.
/// Monitors only sample while their tab is actually visible.
@MainActor
@Observable
final class AppState {
    var tab: AppTab = .clipboard
    var isBubbleVisible = false
    private(set) var lastContentTab: AppTab = .clipboard

    @ObservationIgnored var systemMonitor: SystemMonitor?
    @ObservationIgnored var networkMonitor: NetworkMonitor?

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
    }
}
