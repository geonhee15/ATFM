import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private var statusItem: NSStatusItem?
    private var bubble: BubblePanelController?
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?
    private let appState = AppState()
    private let identityResolver = ProcessIdentityResolver()
    private var systemMonitor: SystemMonitor?
    private var networkMonitor: NetworkMonitor?
    private let speedTester = SpeedTester()
    private let quickActions = QuickActions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenuBuilder.install()

        let vm = ClipboardViewModel(store: store)
        let monitor = ClipboardMonitor { [weak vm] clip in vm?.ingest(clip) }
        vm.monitor = monitor
        monitor.start()
        viewModel = vm
        self.monitor = monitor

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ATFM")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "ATFM"
        }
        statusItem = item

        let systemMonitor = SystemMonitor(resolver: identityResolver)
        let networkMonitor = NetworkMonitor(resolver: identityResolver)
        self.systemMonitor = systemMonitor
        self.networkMonitor = networkMonitor
        appState.systemMonitor = systemMonitor
        appState.networkMonitor = networkMonitor
        appState.quickActions = quickActions

        let root = RootView(appState: appState, viewModel: vm, systemMonitor: systemMonitor,
                            networkMonitor: networkMonitor, speedTester: speedTester,
                            quickActions: quickActions, quit: { NSApp.terminate(nil) })
        let panelHeight = Double(ProcessInfo.processInfo.environment["ATFM_PANEL_HEIGHT"] ?? "") ?? 640
        let bubble = BubblePanelController(
            size: NSSize(width: 372, height: panelHeight),
            content: root,
            anchorProvider: { [weak self] in self?.statusItemScreenRect() }
        )
        bubble.onVisibilityChanged = { [weak self] visible in
            self?.statusItem?.button?.highlight(visible)
            self?.appState.setBubbleVisible(visible)
            if visible { vm.presentationCount += 1 }
        }
        vm.onRequestKeyboardReturn = { [weak bubble] in bubble?.returnKeyboardFocus() }
        appState.applyAppearance = { [weak bubble] mode in bubble?.apply(appearance: mode.nsAppearance) }
        bubble.apply(appearance: appState.appearanceMode.nsAppearance)
        self.bubble = bubble
        NSLog("ATFM: appearance mode %@ (bundle %@)", appState.appearanceMode.rawValue, Bundle.main.bundleIdentifier ?? "nil")

        let env = ProcessInfo.processInfo.environment
        if let tabName = env["ATFM_TAB"], let initial = AppTab(rawValue: tabName) {
            appState.select(initial)
        }
        if env["ATFM_AUTO_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self.bubble?.show() }
            }
        }
        // Debug helper: ATFM_SNAPSHOT=/path/out.png writes a PNG of the bubble (own-window capture).
        if let snapshotPath = env["ATFM_SNAPSHOT"] {
            let delay = Double(env["ATFM_SNAPSHOT_DELAY"] ?? "") ?? 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { self.bubble?.writeSnapshot(to: snapshotPath) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        systemMonitor?.setActive(false)
        networkMonitor?.setActive(false)
    }

    private func statusItemScreenRect() -> CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
        } else {
            bubble?.toggle()
        }
    }

    @objc private func toggleFromMenu() {
        bubble?.toggle()
    }

    private func showContextMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let title = bubble?.isVisible == true ? "ATFM 닫기" : "ATFM 열기"
        let open = NSMenuItem(title: title, action: #selector(toggleFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "ATFM 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
