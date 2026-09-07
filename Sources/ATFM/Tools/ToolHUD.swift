import AppKit
import SwiftUI

enum HUDContent {
    case text(String)
    case color(NSColor, hex: String)
    case message(String, symbol: String)
}

/// Short-lived, click-through notice at the top edge of the screen the mouse is on.
@MainActor
final class ToolHUD {
    var appearance: NSAppearance? {
        didSet { panel?.appearance = appearance }
    }
    /// Debug: write a PNG of the HUD shortly after it appears.
    var snapshotPath: String?

    private var panel: NSPanel?
    private var effect: NSVisualEffectView?
    private var hosting: NSHostingView<HUDRoot>?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    private static let maxWidth: CGFloat = 460

    func show(_ content: HUDContent, duration: TimeInterval) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        guard let effect, let hosting else { return }

        // Measure: ideal single-line width first, then the wrapped height at the clamped width.
        // The root view then gets an explicit frame so the hosting view can't grow past the panel.
        let probe = NSHostingController(rootView: HUDRoot(content: content, size: nil))
        let ideal = probe.sizeThatFits(in: NSSize(width: 4000, height: 400))
        let width = min(ceil(ideal.width), Self.maxWidth)
        let height = ceil(probe.sizeThatFits(in: NSSize(width: width, height: 400)).height)
        let size = NSSize(width: width, height: height)
        hosting.rootView = HUDRoot(content: content, size: size)
        effect.maskImage = Self.roundedMask(size: size, radius: 14)
        generation += 1

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: (visible.maxY - size.height - 10).rounded(),
                           width: size.width, height: size.height)
        panel.setFrame(frame.offsetBy(dx: 0, dy: 10), display: false)
        hosting.frame = effect.bounds          // after the resize: autoresizing from the old size would be wrong
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)

        if let snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated { self?.writeSnapshot(to: snapshotPath) }
            }
        }
    }

    private func hide() {
        guard let panel else { return }
        let frame = panel.frame
        let shown = generation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame.offsetBy(dx: 0, dy: 8), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }   // a newer show() owns the panel now
                self.panel?.orderOut(nil)
            }
        }
        hideWork = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = appearance

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let hosting = NSHostingView(rootView: HUDRoot(content: .message("", symbol: "circle"), size: nil))
        hosting.sizingOptions = []
        effect.addSubview(hosting)
        panel.contentView = effect
        self.effect = effect
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    private static func roundedMask(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        return image
    }

    func writeSnapshot(to path: String) {
        guard let panel else { return }
        let windowID = CGWindowID(panel.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// HUDView with an optional exact frame (nil while measuring).
struct HUDRoot: View {
    let content: HUDContent
    let size: NSSize?

    var body: some View {
        if let size {
            HUDView(content: content).frame(width: size.width, height: size.height)
        } else {
            HUDView(content: content)
        }
    }
}

struct HUDView: View {
    let content: HUDContent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            switch content {
            case .text(let text):
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("텍스트 복사됨")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
            case .color(let color, let hex):
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("색상 복사됨")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(hex)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                }
            case .message(let text, let symbol):
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
    }
}
