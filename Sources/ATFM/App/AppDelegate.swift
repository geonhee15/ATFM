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
    private var checklist: ChecklistStore?
    private let keepAwake = KeepAwake()
    private var gemini: GeminiChat?
    private let converter = FileConverter()
    private let downloader = MediaDownloader()
    private let screenTools = ScreenTools()
    private let nowPlaying = NowPlayingMonitor()
    private var miniPlayer: MiniPlayerController?

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

        let checklist = ChecklistStore(directory: store.directory)
        self.checklist = checklist
        let gemini = GeminiChat(directory: store.directory)
        gemini.copyToPasteboard = { [weak monitor] text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            monitor?.markOwnChange()
        }
        self.gemini = gemini
        let miniPlayer = MiniPlayerController(monitor: nowPlaying)
        self.miniPlayer = miniPlayer
        nowPlaying.start()

        let root = RootView(appState: appState, viewModel: vm, systemMonitor: systemMonitor,
                            networkMonitor: networkMonitor, speedTester: speedTester,
                            quickActions: quickActions, checklist: checklist,
                            keepAwake: keepAwake, gemini: gemini, converter: converter, downloader: downloader, screenTools: screenTools,
                            nowPlaying: nowPlaying, miniPlayer: miniPlayer,
                            quit: { NSApp.terminate(nil) })
        let heightOverride = Double(ProcessInfo.processInfo.environment["ATFM_PANEL_HEIGHT"] ?? "")
        let bubble = BubblePanelController(
            size: NSSize(width: BubblePanelController.defaultSize.width, height: heightOverride ?? BubblePanelController.defaultSize.height),
            useStoredSize: heightOverride == nil,
            content: root,
            anchorProvider: { [weak self] in self?.statusItemScreenRect() }
        )
        bubble.onVisibilityChanged = { [weak self] visible in
            self?.statusItem?.button?.highlight(visible)
            self?.appState.setBubbleVisible(visible)
            if visible { vm.presentationCount += 1 } else { self?.screenTools.hotkeys.cancelRecording() }
        }
        let env = ProcessInfo.processInfo.environment
        screenTools.willStartTool = { [weak bubble] in bubble?.hide() }
        screenTools.hotkeys.handlers = [
            .captureText: { [weak self] in self?.screenTools.captureText() },
            .pickColor: { [weak self] in self?.screenTools.pickColor() },
        ]
        screenTools.hotkeys.focusForRecording = { [weak bubble] in bubble?.panel.makeKey() }
        screenTools.hotkeys.registerAll()
        if let record = env["ATFM_DEBUG_HOTKEY_RECORD"], let action = ToolHotkeys.Action(rawValue: record) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { self.screenTools.hotkeys.beginRecording(action) }
            }
        }
        vm.onRequestKeyboardReturn = { [weak bubble] in bubble?.returnKeyboardFocus() }
        appState.resizeBubble = { [weak bubble] delta in bubble?.applyResize(delta) }
        appState.resetBubbleSize = { [weak bubble] in bubble?.resetSize() }
        if let spec = env["ATFM_DEBUG_RESIZE"] {
            // e.g. "left:-40,bottom:120" applied after the bubble appears
            var delta = BubbleResizeDelta()
            for part in spec.split(separator: ",") {
                let kv = part.split(separator: ":")
                guard kv.count == 2, let value = Double(kv[1]) else { continue }
                switch kv[0] {
                case "left": delta.left = value
                case "right": delta.right = value
                case "bottom": delta.bottom = value
                default: break
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated { bubble.applyResize(delta) }
            }
        }
        appState.applyAppearance = { [weak self] _ in self?.applyLook() }
        ThemeManager.shared.onChange = { [weak self] _ in self?.applyLook() }
        self.bubble = bubble
        applyLook()
        NSLog("ATFM: appearance mode %@, theme %@ (bundle %@)", appState.appearanceMode.rawValue,
              ThemeManager.shared.current.rawValue, Bundle.main.bundleIdentifier ?? "nil")

        if let tabName = env["ATFM_TAB"], let initial = AppTab(rawValue: tabName) {
            appState.select(initial)
        }
        // Debug hooks (dev only): start keep-awake / send a chat prompt right after launch.
        if env["ATFM_DEBUG_AWAKE"] == "1" { keepAwake.setActive(true) }
        if let prompt = env["ATFM_DEBUG_GEMINI_PROMPT"], !prompt.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    gemini.draft = prompt
                    gemini.send()
                }
            }
        }
        if let files = env["ATFM_DEBUG_CONVERT_FILES"], !files.isEmpty {
            converter.add(urls: files.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            if env["ATFM_DEBUG_CONVERT_RUN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    MainActor.assumeIsolated { self.converter.run() }
                }
            }
        }
        if env["ATFM_DEBUG_LYRICS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.miniPlayer?.setLyricsExpanded(true) }
            }
        }
        if let miniPath = env["ATFM_SNAPSHOT_MINI"] {
            let delay = Double(env["ATFM_SNAPSHOT_DELAY"] ?? "") ?? 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) {
                MainActor.assumeIsolated { self.miniPlayer?.writeSnapshot(to: miniPath) }
            }
        }
        if env["ATFM_AUTO_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self.bubble?.show() }
            }
        }
        // Debug helper: ATFM_DEBUG_TOOLS=ocr-bubble|hud-text|hud-color|overlay exercises 빠른 툴 without a mouse;
        // ATFM_SNAPSHOT_HUD=/path/out.png captures the HUD / overlay window.
        if let mode = env["ATFM_DEBUG_TOOLS"] {
            let delay = (Double(env["ATFM_SNAPSHOT_DELAY"] ?? "") ?? 2.0) + 0.5
            screenTools.hud.snapshotPath = env["ATFM_SNAPSHOT_HUD"]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    switch mode {
                    case "ocr-bubble":
                        if let frame = self.bubble?.panel.frame {
                            self.screenTools.debugRecognize(rect: frame.insetBy(dx: 6, dy: 6))
                        }
                    case "hud-text":
                        self.screenTools.hud.show(.text("안녕하세요, 화면에서 읽은 텍스트예요.\n두 번째 줄도 이렇게 보여요."), duration: 3)
                    case "hud-color":
                        self.screenTools.hud.show(.color(NSColor(srgbRed: 0.23, green: 0.48, blue: 0.84, alpha: 1), hex: "#3A7BD5"), duration: 3)
                    case "overlay":
                        let screen = NSScreen.main?.frame ?? .zero
                        let fake = CGRect(x: screen.midX - 220, y: screen.midY - 90, width: 440, height: 180)
                        self.screenTools.debugOverlay(fakeRect: fake, snapshotTo: env["ATFM_SNAPSHOT_HUD"])
                    default:
                        break
                    }
                }
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

    /// Appearance + theme tint for every floating surface.
    private func applyLook() {
        let theme = ThemeManager.shared.current
        let appearance = theme.forcedAppearance ?? appState.appearanceMode.nsAppearance
        bubble?.apply(appearance: appearance)
        bubble?.apply(tint: theme.tint)
        miniPlayer?.apply(appearance: appearance)
        miniPlayer?.apply(tint: theme.tint)
        screenTools.appearance = appearance
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        systemMonitor?.setActive(false)
        networkMonitor?.setActive(false)
        keepAwake.setActive(false)
        converter.cancel()
        downloader.cancel()
        screenTools.hotkeys.unregisterAll()
        nowPlaying.stop()
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
