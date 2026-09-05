import AppKit
import SwiftUI
import Observation

/// Selectable skins. Colors drive the SwiftUI views (via `Theme`) and the panel backdrops.
enum AppTheme: String, CaseIterable, Identifiable {
    case atfm, jarvis, midnight, sage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .atfm: return "ATFM 기본"
        case .jarvis: return "JARVIS"
        case .midnight: return "미드나이트"
        case .sage: return "세이지"
        }
    }

    var subtitle: String {
        switch self {
        case .atfm: return "macOS 시스템 강조색 · 흰 유리"
        case .jarvis: return "네이비 + 시안"
        case .midnight: return "어두운 회색 + 인디고"
        case .sage: return "밝은 유리 + 세이지 그린"
        }
    }

    var accent: Color {
        switch self {
        case .atfm: return .accentColor
        case .jarvis: return Color(red: 0.235, green: 0.863, blue: 1.0)
        case .midnight: return Color(red: 0.43, green: 0.48, blue: 1.0)
        case .sage: return Color(red: 0.18, green: 0.64, blue: 0.42)
        }
    }

    /// Dark skins force the dark appearance regardless of the ATFM dark-mode setting.
    var forcedAppearance: NSAppearance? {
        switch self {
        case .jarvis, .midnight: return NSAppearance(named: .darkAqua)
        case .atfm, .sage: return nil
        }
    }

    /// Translucent color laid over the blur behind the bubble and the mini player.
    var tint: NSColor? {
        switch self {
        case .atfm: return nil
        case .jarvis: return NSColor(srgbRed: 0.02, green: 0.07, blue: 0.16, alpha: 0.55)
        case .midnight: return NSColor(srgbRed: 0.05, green: 0.05, blue: 0.08, alpha: 0.55)
        case .sage: return NSColor(srgbRed: 0.55, green: 0.75, blue: 0.60, alpha: 0.10)
        }
    }
}

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()
    private static let key = "appTheme"

    private(set) var current: AppTheme
    @ObservationIgnored var onChange: ((AppTheme) -> Void)?

    private init() {
        current = AppTheme(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .atfm
    }

    func set(_ theme: AppTheme) {
        current = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.key)
        onChange?(theme)
    }
}
