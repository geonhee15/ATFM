import AppKit

@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: SourceApp, size: CGFloat = 32) -> NSImage {
        let key = "\(app.cacheKey)@\(Int(size))"
        if let cached = cache[key] { return cached }
        var image: NSImage?
        if let path = app.path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let bid = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let base = image ?? NSWorkspace.shared.icon(for: .applicationBundle)
        let result = (base.copy() as? NSImage) ?? base
        result.size = NSSize(width: size, height: size)
        cache[key] = result
        return result
    }

    static func fileIcon(path: String, size: CGFloat = 32) -> NSImage {
        let key = "file:\(path)@\(Int(size))"
        if let cached = cache[key] { return cached }
        let base = NSWorkspace.shared.icon(forFile: path)
        let result = (base.copy() as? NSImage) ?? base
        result.size = NSSize(width: size, height: size)
        cache[key] = result
        return result
    }
}
