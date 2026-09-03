// Generates AppIcon.icns: dark rounded square with a white "sparkles" SF Symbol.
// Usage: swift Scripts/make-icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.27, green: 0.31, blue: 0.40, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.46, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let symSize = NSSize(width: rect.width * 0.56, height: rect.width * 0.56 * (symbol.size.height / symbol.size.width))
        let origin = NSPoint(x: rect.midX - symSize.width / 2, y: rect.midY - symSize.height / 2)
        tinted.draw(in: NSRect(origin: origin, size: symSize))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ATFM-AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(px: base).write(to: tmp.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(px: base * 2).write(to: tmp.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp.path, "-o", output]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
print(task.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
exit(task.terminationStatus)
