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
    var tone: Tone = .auto {
        didSet { panel?.appearance = tone.appearance }
    }
    /// Horizontal/bottom inset so the sheet reads as a floating pane rather than a slab.
    private let inset: CGFloat = 0
    static let cornerRadius: CGFloat = 12

    func show(windowFrame: NSRect, topInset: CGFloat, clearHeight: CGFloat, animated: Bool) {
        let panel = panel ?? makePanel()
        if panel.frame != windowFrame {
            panel.setFrame(windowFrame, display: false)
        }
        let coveredHeight = windowFrame.height - topInset - clearHeight
        guard coveredHeight >= 24 else {
            glass?.isHidden = true
            if !isVisible { panel.orderFrontRegardless(); isVisible = true }
            return
        }
        let target = NSRect(x: inset, y: clearHeight, width: windowFrame.width - inset * 2, height: coveredHeight)
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
        if abs(target.minY - lastGlassFrame.minY) < 3 && abs(target.height - lastGlassFrame.height) < 3 && target.width == lastGlassFrame.width { return }
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

        let glass = makeGlass()
        glass.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.addSubview(glass)
        self.glass = glass
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
        let fade: CGFloat = min(28, size.height * 0.3)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            path.addClip()
            let gradient = NSGradient(colorsAndLocations: (NSColor.black.withAlphaComponent(0), 0),
                                      (NSColor.black, fade / max(fade, rect.height)),
                                      (NSColor.black, 1))
            gradient?.draw(in: rect, angle: 90)
            return true
        }
        effect.maskImage = image
    }
}
