import AppKit

struct RegionSelection {
    let rect: CGRect          // Cocoa screen coordinates
    let windowID: CGWindowID  // the overlay window the selection was made on
}

/// Full-screen dimmed overlays (one per display) where the user drags a rectangle, screenshot-style.
@MainActor
final class RegionSelector {
    private var windows: [SelectionWindow] = []
    private var completion: ((RegionSelection?) -> Void)?
    private var previousApp: NSRunningApplication?

    func begin(completion: @escaping (RegionSelection?) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen, selector: self)
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)   // so Esc reaches the overlay
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    /// Called by the overlay on mouse-up / Esc. The completion runs while the overlays are still on
    /// screen so the caller can capture "everything below the overlay".
    func finish(with rect: CGRect?, from window: SelectionWindow) {
        guard let completion else { return }
        self.completion = nil
        let selection = rect.map { RegionSelection(rect: $0, windowID: CGWindowID(window.windowNumber)) }
        completion(selection)
        for overlay in windows { overlay.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
    }

    func cancel() {
        if let window = windows.first { finish(with: nil, from: window) }
    }

    var firstWindowID: CGWindowID? {
        windows.first.map { CGWindowID($0.windowNumber) }
    }

    func debugPreview(rect: CGRect) {
        windows.first?.selectionView.debugShow(rect: rect)
    }
}

final class SelectionWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen, selector: RegionSelector) {
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), selector: selector)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        selectionView.cancel()
    }
}

final class SelectionView: NSView {
    private weak var selector: RegionSelector?
    private var dragStart: NSPoint?
    private var selection: NSRect?

    init(frame: NSRect, selector: RegionSelector) {
        self.selector = selector
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        guard let window = window as? SelectionWindow else { return }
        if let selection, selection.width >= 4, selection.height >= 4 {
            selector?.finish(with: window.convertToScreen(selection), from: window)
        } else {
            selector?.finish(with: nil, from: window)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel() } else { super.keyDown(with: event) }
    }

    func cancel() {
        guard let window = window as? SelectionWindow else { return }
        selector?.finish(with: nil, from: window)
    }

    func debugShow(rect: NSRect) {
        selection = rect
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)                       // punch the hole
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            let label = "\(Int(selection.width)) × \(Int(selection.height))"
            let below = selection.minY - 16
            let labelY = below > 12 ? below : selection.minY + 14
            drawPill(label, centeredAt: NSPoint(x: selection.midX, y: labelY), size: 11)
        } else {
            drawPill("드래그해서 텍스트 영역을 선택하세요  ·  Esc 취소",
                     centeredAt: NSPoint(x: bounds.midX, y: bounds.maxY - 64), size: 13)
        }
    }

    private func drawPill(_ string: String, centeredAt point: NSPoint, size: CGFloat) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        let pill = NSRect(x: (point.x - textSize.width / 2 - 12).rounded(), y: (point.y - textSize.height / 2 - 6).rounded(),
                          width: (textSize.width + 24).rounded(), height: (textSize.height + 12).rounded())
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 12, y: pill.minY + 6))
    }
}
