import AppKit
import SwiftUI
import Observation

/// Selectable skins. Colors drive the SwiftUI views (via `Theme`), the panel backdrops, and are
/// exported to Security-Protocol-1's theme.json so its lockdown HUD / UNLOCK button match.
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
        case .jarvis: return "네이비 + 시안 (Security Protocol 1 원본 스타일)"
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

    /// Palette for Security-Protocol-1 (theme.json). Hex RGB strings.
    var sp1Theme: [String: Any] {
        switch self {
        case .atfm:
            return ["name": "ATFM", "accent": "#0A84FF", "text": "#FFFFFF", "dim": "#9AA4B2",
                    "bg": "#0B0F17", "tint": "#111827", "shade_alpha": 0.55, "button_bg": "#1C1C1E", "button_alpha": 0.9]
        case .jarvis:
            return ["name": "JARVIS", "accent": "#3CDCFF", "text": "#FAF5E6", "dim": "#8EC8E0",
                    "bg": "#050B16", "tint": "#08162D", "shade_alpha": 0.62, "button_bg": "#020C1F", "button_alpha": 0.85]
        case .midnight:
            return ["name": "MIDNIGHT", "accent": "#6E7BFF", "text": "#F2F2F7", "dim": "#8E8E93",
                    "bg": "#0A0A10", "tint": "#14141C", "shade_alpha": 0.6, "button_bg": "#161622", "button_alpha": 0.9]
        case .sage:
            return ["name": "SAGE", "accent": "#4CD08A", "text": "#F5FFF9", "dim": "#9BC7AE",
                    "bg": "#06120B", "tint": "#0C1F14", "shade_alpha": 0.5, "button_bg": "#0F2418", "button_alpha": 0.9]
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
