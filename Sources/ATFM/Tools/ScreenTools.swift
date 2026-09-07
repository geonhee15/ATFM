import AppKit
import Observation

/// One result of 빠른 툴 — kept in memory for quick re-copying.
struct ToolRecord: Identifiable {
    enum Kind {
        case text(String)
        case color(NSColor, hex: String)
    }
    let id = UUID()
    let kind: Kind
    let date: Date
}

/// 빠른 툴: screen text capture (region → OCR → clipboard) and screen color picking (eyedropper → HEX).
/// Both flows end with a short HUD at the top edge of the screen (see ToolHUD).
@MainActor
@Observable
final class ScreenTools {
    enum Status: Equatable {
        case idle, selecting, recognizing, picking
        case done(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var hasScreenAccess = CGPreflightScreenCaptureAccess()
    private(set) var records: [ToolRecord] = []

    /// Hides the bubble before an overlay / the sampler appears (set by AppDelegate).
    @ObservationIgnored var willStartTool: (() -> Void)?
    /// Appearance for the HUD (theme / ATFM dark mode), kept in sync by AppDelegate.applyLook.
    @ObservationIgnored var appearance: NSAppearance? {
        didSet { hud.appearance = appearance }
    }
    @ObservationIgnored let hud = ToolHUD()
    let hotkeys = ToolHotkeys()
    @ObservationIgnored private var selector: RegionSelector?
    @ObservationIgnored private var busy = false

    // MARK: Screen Recording access

    func refreshAccess() {
        hasScreenAccess = CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt (macOS lists ATFM under Screen Recording); the grant applies after a relaunch.
    @discardableResult
    func requestScreenAccess() -> Bool {
        hasScreenAccess = CGRequestScreenCaptureAccess()
        return hasScreenAccess
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Text from the screen

    func captureText() {
        guard !busy else { return }
        refreshAccess()
        guard hasScreenAccess else {
            if !requestScreenAccess() {
                status = .failed("화면 기록 권한을 허용한 뒤 ATFM을 다시 실행해 주세요")
            }
            return
        }
        busy = true
        willStartTool?()
        status = .selecting
        let selector = RegionSelector()
        self.selector = selector
        selector.begin { [weak self] selection in
            guard let self else { return }
            self.selector = nil
            guard let selection else {
                self.busy = false
                self.status = .idle
                return
            }
            self.recognize(rect: selection.rect, belowWindow: selection.windowID)
        }
    }

    private func recognize(rect: CGRect, belowWindow windowID: CGWindowID?, copies: Bool = true) {
        status = .recognizing
        guard let image = Self.capture(rect: rect, belowWindow: windowID) else {
            finishText(nil, error: "화면을 캡처하지 못했어요", copies: copies)
            return
        }
        Task { [weak self] in
            let text = await ScreenOCR.recognize(image)
            self?.finishText(text, error: nil, copies: copies)
        }
    }

    private func finishText(_ text: String?, error: String?, copies: Bool) {
        busy = false
        if let error {
            status = .failed(error)
            hud.show(.message(error, symbol: "exclamationmark.triangle"), duration: 1.4)
            return
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            status = .failed("선택한 영역에서 텍스트를 찾지 못했어요")
            hud.show(.message("텍스트를 찾지 못했어요", symbol: "text.magnifyingglass"), duration: 1.2)
            return
        }
        if copies {
            copy(trimmed)
            records.insert(ToolRecord(kind: .text(trimmed), date: Date()), at: 0)
            trimRecords()
        }
        status = .done("텍스트 \(trimmed.count)자를 복사했어요")
        let lines = trimmed.split(separator: "\n").count
        hud.show(.text(trimmed), duration: min(2.2, 1.0 + 0.3 * Double(min(lines, 4))))
    }

    /// Quartz-space capture of a screen rect. With a window ID, only what lies below that window
    /// (i.e. under our selection overlay) is captured; without one, everything on screen.
    static func capture(rect: CGRect, belowWindow windowID: CGWindowID?) -> CGImage? {
        guard let primary = NSScreen.screens.first else { return nil }
        let cgRect = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY,
                            width: rect.width, height: rect.height).integral
        if let windowID {
            return CGWindowListCreateImage(cgRect, .optionOnScreenBelowWindow, windowID, [.bestResolution, .boundsIgnoreFraming])
        }
        return CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming])
    }

    // MARK: Color from the screen

    func pickColor() {
        guard !busy else { return }
        busy = true
        willStartTool?()
        status = .picking
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        NSColorSampler().show { [weak self] picked in
            let srgb = picked?.usingColorSpace(.sRGB)
            let rgb: (Double, Double, Double)? = srgb.map {
                (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        previous.activate()
                    }
                    self?.finishColor(rgb)
                }
            }
        }
    }

    private func finishColor(_ rgb: (Double, Double, Double)?) {
        busy = false
        guard let (r, g, b) = rgb else {
            status = .idle
            return
        }
        let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let hex = String(format: "#%02X%02X%02X",
                         Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        copy(hex)
        records.insert(ToolRecord(kind: .color(color, hex: hex), date: Date()), at: 0)
        trimRecords()
        status = .done("\(hex) 복사했어요")
        hud.show(.color(color, hex: hex), duration: 1.0)
    }

    // MARK: Shared

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copy(record: ToolRecord) {
        switch record.kind {
        case .text(let text):
            copy(text)
            status = .done("텍스트를 다시 복사했어요")
        case .color(_, let hex):
            copy(hex)
            status = .done("\(hex) 다시 복사했어요")
        }
    }

    func remove(record: ToolRecord) {
        records.removeAll { $0.id == record.id }
    }

    private func trimRecords() {
        if records.count > 8 { records.removeLast(records.count - 8) }
    }

    // MARK: Debug hooks (ATFM_DEBUG_TOOLS)

    /// OCR of a screen rect without touching the clipboard — ATFM's own windows are capturable without
    /// Screen Recording access, so the bubble itself makes a good offline test target.
    func debugRecognize(rect: CGRect) {
        busy = true
        recognize(rect: rect, belowWindow: nil, copies: false)
    }

    /// Shows the selection overlay with a fake selection, snapshots it, then cancels.
    func debugOverlay(fakeRect: CGRect, snapshotTo path: String?) {
        let selector = RegionSelector()
        self.selector = selector
        selector.begin { [weak self] _ in self?.selector = nil }
        selector.debugPreview(rect: fakeRect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                if let path, let windowID = selector.firstWindowID,
                   let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                selector.cancel()
            }
        }
    }
}
