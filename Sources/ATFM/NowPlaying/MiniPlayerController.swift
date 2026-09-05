import AppKit
import SwiftUI
import Observation

enum MiniPlayerCorner: String, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomRight: return "오른쪽 아래"
        case .bottomLeft: return "왼쪽 아래"
        case .topRight: return "오른쪽 위"
        case .topLeft: return "왼쪽 위"
        }
    }
}

enum MiniPlayerSourceFilter: String, CaseIterable, Identifiable {
    case spotify, spotifyAndBrowsers, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spotify: return "Spotify 앱만"
        case .spotifyAndBrowsers: return "Spotify 앱 + 브라우저"
        case .all: return "모든 앱"
        }
    }
}

/// Owns the always-on-top mini player panel and decides when it should be on screen.
@MainActor
@Observable
final class MiniPlayerController {
    static let size = NSSize(width: 330, height: 92)
    static let lyricsHeight: CGFloat = 236
    private static let margin: CGFloat = 16

    private(set) var isEnabled: Bool
    private(set) var sourceFilter: MiniPlayerSourceFilter
    private(set) var showWhenPaused: Bool
    private(set) var corner: MiniPlayerCorner
    private(set) var isVisible = false
    private(set) var isLyricsExpanded: Bool
    var currentSize: NSSize { isLyricsExpanded ? NSSize(width: Self.size.width, height: Self.size.height + Self.lyricsHeight) : Self.size }

    let monitor: NowPlayingMonitor
    let lyrics: LyricsController
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var container: MiniPlayerContainerView?
    @ObservationIgnored private var customOrigin: CGPoint?
    @ObservationIgnored private var programmaticMove = false
    @ObservationIgnored private var appearance: NSAppearance?
    @ObservationIgnored private var tint: NSColor?

    private enum Key {
        static let enabled = "miniPlayerEnabled"
        static let source = "miniPlayerSource"
        static let paused = "miniPlayerShowWhenPaused"
        static let corner = "miniPlayerCorner"
        static let origin = "miniPlayerOrigin"
        static let lyrics = "miniPlayerLyricsExpanded"
    }

    init(monitor: NowPlayingMonitor) {
        self.monitor = monitor
        lyrics = LyricsController(monitor: monitor)
        let defaults = UserDefaults.standard
        isLyricsExpanded = defaults.bool(forKey: Key.lyrics)
        isEnabled = (defaults.object(forKey: Key.enabled) as? Bool) ?? true
        sourceFilter = MiniPlayerSourceFilter(rawValue: defaults.string(forKey: Key.source) ?? "") ?? .spotifyAndBrowsers
        showWhenPaused = (defaults.object(forKey: Key.paused) as? Bool) ?? true
        corner = MiniPlayerCorner(rawValue: defaults.string(forKey: Key.corner) ?? "") ?? .bottomRight
        if let stored = defaults.array(forKey: Key.origin) as? [Double], stored.count == 2 {
            customOrigin = CGPoint(x: stored[0], y: stored[1])
        }
        lyrics.autoFetch = isLyricsExpanded
        observe()
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Key.enabled)
        update()
    }

    /// The ✕ on the player: hide until re-enabled from the ATFM bubble.
    func dismissByUser() { setEnabled(false) }

    func setSourceFilter(_ filter: MiniPlayerSourceFilter) {
        sourceFilter = filter
        UserDefaults.standard.set(filter.rawValue, forKey: Key.source)
        update()
    }

    func setShowWhenPaused(_ on: Bool) {
        showWhenPaused = on
        UserDefaults.standard.set(on, forKey: Key.paused)
        update()
    }

    func setCorner(_ value: MiniPlayerCorner) {
        corner = value
        customOrigin = nil
        UserDefaults.standard.set(value.rawValue, forKey: Key.corner)
        UserDefaults.standard.removeObject(forKey: Key.origin)
        reposition()
    }

    /// Debug: capture the floating panel into a PNG (own-window capture, no screen-recording permission).
    func writeSnapshot(to path: String) {
        guard let panel, isVisible else { NSLog("ATFM: mini player not visible, no snapshot"); return }
        let windowID = CGWindowID(panel.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else { return }
        if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            NSLog("ATFM: mini player snapshot written to %@", path)
        }
    }

    func apply(appearance: NSAppearance?) {
        self.appearance = appearance
        panel?.appearance = appearance
    }

    func apply(tint: NSColor?) {
        self.tint = tint
        container?.tintColor = tint
    }

    /// Opens/closes the lyrics box. The window grows away from the nearest screen edge so it stays on screen.
    func setLyricsExpanded(_ expanded: Bool) {
        guard expanded != isLyricsExpanded else { return }
        isLyricsExpanded = expanded
        UserDefaults.standard.set(expanded, forKey: Key.lyrics)
        lyrics.autoFetch = expanded
        guard let panel, isVisible else { return }
        let old = panel.frame
        let newSize = currentSize
        let screen = NSScreen.main?.visibleFrame ?? old
        let anchorTop = old.midY > screen.midY   // upper half: keep the top edge, grow downward
        var origin = old.origin
        if anchorTop { origin.y = old.maxY - newSize.height }
        origin.y = max(screen.minY, min(origin.y, screen.maxY - newSize.height))
        programmaticMove = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: origin, size: newSize), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.programmaticMove = false }
        }
    }

    // MARK: Visibility

    private func observe() {
        withObservationTracking {
            _ = monitor.track
            _ = monitor.artwork
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    func sourceAllowed(_ track: NowPlayingTrack) -> Bool {
        switch sourceFilter {
        case .spotify: return track.isSpotifyApp
        case .spotifyAndBrowsers: return track.isSpotifyApp || track.isBrowser
        case .all: return true
        }
    }

    func update() {
        let shouldShow: Bool
        if isEnabled, let track = monitor.track, sourceAllowed(track), track.isPlaying || showWhenPaused {
            shouldShow = true
        } else {
            shouldShow = false
        }
        if shouldShow { show() } else { hide() }
    }

    private func show() {
        let panel = ensurePanel()
        guard !isVisible else { return }
        reposition()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isVisible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: currentSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.appearance = appearance

        let container = MiniPlayerContainerView(frame: NSRect(origin: .zero, size: currentSize))
        let hosting = NSHostingView(rootView: AnyView(MiniPlayerView(monitor: monitor, controller: self)))
        hosting.sizingOptions = []
        container.install(hosting: hosting)
        container.tintColor = tint
        panel.contentView = container
        self.container = container

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidMove() }
        }
        self.panel = panel
        return panel
    }

    private func panelDidMove() {
        guard !programmaticMove, let panel else { return }
        customOrigin = panel.frame.origin
        UserDefaults.standard.set([panel.frame.origin.x, panel.frame.origin.y], forKey: Key.origin)
    }

    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = currentSize
        var origin: CGPoint
        if let customOrigin, visible.insetBy(dx: -size.width + 40, dy: -size.height + 40).contains(customOrigin) {
            origin = customOrigin
        } else {
            let x = corner == .bottomRight || corner == .topRight ? visible.maxX - size.width - Self.margin : visible.minX + Self.margin
            let y = corner == .bottomRight || corner == .bottomLeft ? visible.minY + Self.margin : visible.maxY - size.height - Self.margin
            origin = CGPoint(x: x, y: y)
        }
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        programmaticMove = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        programmaticMove = false
    }
}

/// Rounded translucent backdrop for the mini player (same technique as the bubble).
final class MiniPlayerContainerView: NSView {
    private let effect = NSVisualEffectView()
    private let tintView = PassthroughView()
    private let tintMask = CAShapeLayer()
    private let radius: CGFloat = 16
    private var hosting: NSView?
    var tintColor: NSColor? {
        didSet {
            tintView.layer?.backgroundColor = tintColor?.cgColor
            tintView.isHidden = tintColor == nil
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect)
        tintView.wantsLayer = true
        tintView.layer?.mask = tintMask
        tintView.isHidden = true
        addSubview(tintView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(hosting: NSView) {
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = radius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        addSubview(hosting)
        self.hosting = hosting
        needsLayout = true
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        tintView.frame = bounds
        tintMask.frame = bounds
        tintMask.path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        hosting?.frame = bounds
        let r = radius
        effect.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
    }
}
