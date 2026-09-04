import AppKit
import SwiftUI

// MARK: - Geometry

enum BubbleMetrics {
    static let arrowWidth: CGFloat = 26
    static let arrowHeight: CGFloat = 11
    static let cornerRadius: CGFloat = 16
}

enum BubbleShape {
    /// Single-contour outline: rounded body with a soft arrow on the top edge pointing at `arrowX`.
    static func path(in rect: CGRect, arrowX: CGFloat) -> NSBezierPath {
        let r = BubbleMetrics.cornerRadius
        let aw = BubbleMetrics.arrowWidth
        let ah = BubbleMetrics.arrowHeight
        let bodyTop = rect.maxY - ah
        let ax = min(max(arrowX, rect.minX + r + aw / 2 + 2), rect.maxX - r - aw / 2 - 2)

        let apex = CGPoint(x: ax, y: rect.maxY)
        let left = CGPoint(x: ax - aw / 2, y: bodyTop)
        let right = CGPoint(x: ax + aw / 2, y: bodyTop)
        let tipRadius: CGFloat = 3.5
        func towards(_ from: CGPoint, _ to: CGPoint, _ d: CGFloat) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let len = max(0.001, sqrt(dx * dx + dy * dy))
            return CGPoint(x: from.x + dx / len * d, y: from.y + dy / len * d)
        }
        let leftTip = towards(apex, left, tipRadius)
        let rightTip = towards(apex, right, tipRadius)

        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 360)
        path.line(to: CGPoint(x: rect.maxX, y: bodyTop - r))
        path.appendArc(withCenter: CGPoint(x: rect.maxX - r, y: bodyTop - r), radius: r, startAngle: 0, endAngle: 90)
        path.line(to: right)
        path.line(to: rightTip)
        path.curve(to: leftTip, controlPoint1: apex, controlPoint2: apex)
        path.line(to: left)
        path.line(to: CGPoint(x: rect.minX + r, y: bodyTop))
        path.appendArc(withCenter: CGPoint(x: rect.minX + r, y: bodyTop - r), radius: r, startAngle: 90, endAngle: 180)
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.appendArc(withCenter: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }
}

// MARK: - Views

/// Translucent "popover" material masked to the bubble outline.
final class BubbleBackgroundView: NSView {
    var arrowX: CGFloat = 0 { didSet { needsLayout = true } }
    private let effect = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        effect.frame = bounds
        let ax = arrowX
        effect.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            BubbleShape.path(in: rect, arrowX: ax).fill()
            return true
        }
    }
}

/// Hairline border on top of everything; ignores mouse events.
final class BubbleBorderView: NSView {
    var arrowX: CGFloat = 0 { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.10)
        let path = BubbleShape.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), arrowX: arrowX)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class BubbleContainerView: NSView {
    var arrowX: CGFloat = 0 {
        didSet {
            background.arrowX = arrowX
            border.arrowX = arrowX
        }
    }
    private let background = BubbleBackgroundView()
    private let border = BubbleBorderView()
    private let hosting: NSView

    init(hosting: NSView, frame: NSRect) {
        self.hosting = hosting
        super.init(frame: frame)
        wantsLayer = true
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = BubbleMetrics.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        addSubview(background)
        addSubview(hosting)
        addSubview(border)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        background.frame = bounds
        border.frame = bounds
        hosting.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - BubbleMetrics.arrowHeight)
    }
}

// MARK: - Panel

final class BubblePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns the speech-bubble panel that hangs below the status item.
/// It is a non-activating floating panel, so it stays visible while the user works in other apps.
@MainActor
final class BubblePanelController {
    let panel: BubblePanel
    private let container: BubbleContainerView
    private let size: NSSize
    private let anchorProvider: () -> CGRect?
    private(set) var isVisible = false
    var onVisibilityChanged: ((Bool) -> Void)?

    init<Content: View>(size: NSSize, content: Content, anchorProvider: @escaping () -> CGRect?) {
        self.size = size
        self.anchorProvider = anchorProvider

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.sizingOptions = []
        container = BubbleContainerView(hosting: hosting, frame: NSRect(origin: .zero, size: size))

        panel = BubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = container
        panel.onCancel = { [weak self] in self?.hide() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// nil follows the system; otherwise forces light/dark for this panel only.
    func apply(appearance: NSAppearance?) {
        panel.appearance = appearance
    }

    func show() {
        guard let anchor = anchorProvider() else { return }
        let frame = targetFrame(anchor: anchor)
        container.arrowX = anchor.midX - frame.minX
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()

        panel.setFrame(frame.offsetBy(dx: 0, dy: -8), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isVisible = true
        onVisibilityChanged?(true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        onVisibilityChanged?(false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// Re-anchors the panel if the status item or screen layout moved.
    func reposition() {
        guard isVisible, let anchor = anchorProvider() else { return }
        let frame = targetFrame(anchor: anchor)
        container.arrowX = anchor.midX - frame.minX
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// After the user picks an item while the search field held keyboard focus, hand the keyboard
    /// back to the app they were working in so ⌘V goes there. Re-ordering without key status does that.
    func returnKeyboardFocus() {
        guard isVisible, panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Captures this panel's own window into a PNG (no screen-recording permission needed for own windows).
    func writeSnapshot(to path: String) {
        let windowID = CGWindowID(panel.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else {
            NSLog("ATFM: snapshot failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            NSLog("ATFM: snapshot written to \(path)")
        }
    }

    private func targetFrame(anchor: CGRect) -> CGRect {
        let probe = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - 1
        return CGRect(x: x.rounded(), y: max(y.rounded(), visible.minY), width: size.width, height: size.height)
    }
}
