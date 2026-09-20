import AppKit

/// A click-through glass sheet floated over another app's window. On macOS 26 it is real Liquid
/// Glass (`NSGlassEffectView`); earlier systems get a vibrancy blur with a soft bottom fade.
@MainActor
final class PrivacyOverlay {
    enum Tone: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "자동"
            case .light: return "밝게"
            case .dark: return "어둡게"
            }
        }
        var appearance: NSAppearance? {
            switch self {
            case .auto: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    private var panel: NSPanel?
    private var glass: NSView?
    private var fallbackEffect: NSVisualEffectView?
    private var lastGlassFrame: NSRect = .zero
    private(set) var isVisible = false
    var windowNumber: Int { panel?.windowNumber ?? 0 }
    var debugMaskDescription: String { sheet?.maskDebugDescription ?? "no sheet" }
    var tone: Tone = .auto {
        didSet { panel?.appearance = tone.appearance }
    }
    /// Horizontal/bottom inset so the sheet reads as a floating pane rather than a slab.
    private let inset: CGFloat = 0
    static let cornerRadius: CGFloat = 12
    /// Total height of the soft bottom edge; 35% of it lies below the clear boundary.
    private var currentFeather: CGFloat = 40
    static let topFeatherHeight: CGFloat = 12
    private var sheet: GlassSheet?

    /// - cover: the chat area in window coordinates (origin bottom-left); its bottom is the clear boundary.
    /// - feather: total height of the soft bottom edge (centred a little above the boundary).
    func show(windowFrame: NSRect, cover: NSRect, feather: CGFloat, animated: Bool) {
        currentFeather = max(6, feather)
        let panel = panel ?? makePanel()
        if panel.frame != windowFrame {
            panel.setFrame(windowFrame, display: false)
        }
        guard cover.height >= 24, cover.width >= 40 else {
            glass?.isHidden = true
            if !isVisible { panel.orderFrontRegardless(); isVisible = true }
            return
        }
        let toe = min(currentFeather * 0.35, cover.minY)
        let target = NSRect(x: cover.minX, y: cover.minY - toe, width: cover.width, height: cover.height + toe)
        sheet?.topFeather = cover.maxY < windowFrame.height - 2 ? Self.topFeatherHeight : 0
        if sheet?.bottomFeather != currentFeather { sheet?.bottomFeather = currentFeather }
        glass?.isHidden = false
        if !isVisible {
            glass?.frame = target
            lastGlassFrame = target
            updateMask(size: target.size)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            isVisible = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 1
            }
            return
        }
        if abs(target.minY - lastGlassFrame.minY) < 3 && abs(target.height - lastGlassFrame.height) < 3 && target.width == lastGlassFrame.width {
            updateMask(size: target.size)
            return
        }
        lastGlassFrame = target
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glass?.animator().frame = target
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.updateMask(size: target.size) }
            }
        } else {
            glass?.frame = target
            updateMask(size: target.size)
        }
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    // MARK: Building

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = tone.appearance

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        let glassView = makeGlass()
        let sheet = GlassSheet(glass: glassView, featherable: fallbackEffect == nil, bottomFeather: currentFeather)
        sheet.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.addSubview(sheet)
        self.sheet = sheet
        self.glass = sheet
        self.panel = panel
        return panel
    }

    private func makeGlass() -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = Self.cornerRadius
            let content = NSView()
            content.wantsLayer = true
            view.contentView = content
            return view
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.masksToBounds = true
        // A hairline highlight along the top edge, like light catching the sheet.
        let highlight = CAGradientLayer()
        highlight.colors = [NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        highlight.startPoint = CGPoint(x: 0.5, y: 1)
        highlight.endPoint = CGPoint(x: 0.5, y: 0.97)
        highlight.frame = effect.bounds
        highlight.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        effect.layer?.addSublayer(highlight)
        fallbackEffect = effect
        return effect
    }

    /// Soft fade at the bottom edge of the vibrancy fallback so the sheet doesn't end in a hard line.
    private func updateMask(size: CGSize) {
        guard let effect = fallbackEffect, size.width > 0, size.height > 0 else { return }
        let fade = min(currentFeather, size.height * 0.5)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            path.addClip()
            let h = max(fade, rect.height)
            let stops = GlassSheet.rampStops(fade: fade, height: h)
            let gradient = NSGradient(colorsAndLocations: (NSColor.black.withAlphaComponent(0), 0),
                                      (NSColor.black.withAlphaComponent(stops[1].1), stops[1].0),
                                      (NSColor.black.withAlphaComponent(stops[2].1), stops[2].0),
                                      (NSColor.black.withAlphaComponent(stops[3].1), stops[3].0),
                                      (NSColor.black, stops[4].0),
                                      (NSColor.black, 1))
            gradient?.draw(in: rect, angle: 90)
            return true
        }
        effect.maskImage = image
    }
}


/// Layer-backed holder for the glass with feathered top/bottom edges (a gradient layer mask).
/// The vibrancy fallback masks itself via `maskImage`, so the layer mask is only used for real glass.
final class GlassSheet: NSView {
    private let glass: NSView
    private let featherable: Bool
    private let feather = CAGradientLayer()
    var bottomFeather: CGFloat {
        didSet { if oldValue != bottomFeather { updateMask() } }
    }
    var topFeather: CGFloat = 0 {
        didSet { if oldValue != topFeather { updateMask() } }
    }

    init(glass: NSView, featherable: Bool, bottomFeather: CGFloat) {
        self.glass = glass
        self.featherable = featherable
        self.bottomFeather = bottomFeather
        super.init(frame: .zero)
        wantsLayer = true
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        if featherable {
            feather.startPoint = CGPoint(x: 0.5, y: 0)     // bottom → top (layer coordinates are not flipped)
            feather.endPoint = CGPoint(x: 0.5, y: 1)
            feather.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.mask = feather
        }
    }

    required init?(coder: NSCoder) { nil }

    var maskDebugDescription: String {
        "sheet frame=\(frame.integral) bounds=\(bounds.integral) glass=\(glass.frame.integral) mask.frame=\(feather.frame.integral) " +
        "locations=\((feather.locations ?? []).map { String(format: "%.3f", $0.doubleValue) }) " +
        "alphas=\((feather.colors as? [CGColor] ?? []).map { String(format: "%.2f", $0.alpha) }) feather=\(bottomFeather) top=\(topFeather) flipped=\(layer?.isGeometryFlipped ?? false)"
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        guard featherable else { return }
        feather.frame = bounds
        updateMask()
    }

    /// S-shaped ramp over `fade` points from the bottom: (location fraction, alpha).
    static func rampStops(fade: CGFloat, height: CGFloat) -> [(CGFloat, CGFloat)] {
        let f = fade / max(height, 1)
        return [(0, 0), (f * 0.25, 0.08), (f * 0.5, 0.5), (f * 0.75, 0.92), (f, 1)]
    }

    private func updateMask() {
        guard featherable else { return }
        let height = bounds.height
        guard height > 0 else { return }
        let bottom = min(bottomFeather, height * 0.5)
        let top = min(topFeather, height * 0.25)
        let black = NSColor.black
        var stops = Self.rampStops(fade: bottom, height: height)
        if top > 0 {
            stops.append(((height - top) / height, 1))
            stops.append((1, 0))
        } else {
            stops.append((1, 1))
        }
        feather.colors = stops.map { black.withAlphaComponent($0.1).cgColor }
        feather.locations = stops.map { NSNumber(value: Double($0.0)) }
    }
}
