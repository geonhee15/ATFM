import Foundation

/// UserDefaults keys shared between the SwiftUI settings screen (@AppStorage) and the capture pipeline.
enum SettingsKey {
    static let maxItems = "maxItems"
    static let moveDuplicatesToTop = "moveDuplicatesToTop"
    static let captureImages = "captureImages"
    static let captureFiles = "captureFiles"
}

enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static var maxItems: Int { (defaults.object(forKey: SettingsKey.maxItems) as? Int) ?? 2000 }
    static var moveDuplicatesToTop: Bool { (defaults.object(forKey: SettingsKey.moveDuplicatesToTop) as? Bool) ?? true }
    static var captureImages: Bool { (defaults.object(forKey: SettingsKey.captureImages) as? Bool) ?? true }
    static var captureFiles: Bool { (defaults.object(forKey: SettingsKey.captureFiles) as? Bool) ?? true }
}
