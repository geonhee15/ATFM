import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private var statusItem: NSStatusItem?
    private var bubble: BubblePanelController?
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?

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

        let root = RootView(viewModel: vm, quit: { NSApp.terminate(nil) })
        let bubble = BubblePanelController(
            size: NSSize(width: 372, height: 640),
            content: root,
            anchorProvider: { [weak self] in self?.statusItemScreenRect() }
        )
        bubble.onVisibilityChanged = { [weak self] visible in
            self?.statusItem?.button?.highlight(visible)
            if visible { vm.presentationCount += 1 }
        }
        vm.onRequestKeyboardReturn = { [weak bubble] in bubble?.returnKeyboardFocus() }
        self.bubble = bubble

        let env = ProcessInfo.processInfo.environment
        if env["ATFM_AUTO_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self.bubble?.show() }
            }
        }
        // Debug helper: ATFM_SNAPSHOT=/path/out.png writes a PNG of the bubble (own-window capture).
        if let snapshotPath = env["ATFM_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                MainActor.assumeIsolated { self.bubble?.writeSnapshot(to: snapshotPath) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
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
