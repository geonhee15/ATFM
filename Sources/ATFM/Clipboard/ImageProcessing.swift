import AppKit

enum ImageProcessing {
    struct Result {
        let png: Data
        let thumb: Data?
        let width: Int
        let height: Int
    }

    /// Normalises any bitmap pasteboard payload to PNG and produces a small PNG thumbnail.
    static func process(data: Data, isPNG: Bool) -> Result? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return nil }
        let png: Data
        if isPNG {
            png = data
        } else {
            guard let converted = rep.representation(using: .png, properties: [:]) else { return nil }
            png = converted
        }
        let thumb = makeThumbnail(from: rep, maxSide: 360)
        return Result(png: png, thumb: thumb, width: width, height: height)
    }

    static func makeThumbnail(from rep: NSBitmapImageRep, maxSide: CGFloat) -> Data? {
        let w = CGFloat(rep.pixelsWide)
        let h = CGFloat(rep.pixelsHigh)
        let scale = min(1, maxSide / max(w, h))
        let tw = max(1, Int((w * scale).rounded()))
        let th = max(1, Int((h * scale).rounded()))
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        out.size = NSSize(width: tw, height: th)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
        return out.representation(using: .png, properties: [:])
    }
}
