import AppKit
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "시스템"
        case .light: return "라이트"
        case .dark: return "다크"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// State and handlers for the 빠른 동작 tab.
@MainActor
@Observable
final class QuickActions {
    struct Status: Equatable {
        let id: String
        let text: String
        let isError: Bool
    }

    var keyboardBacklightAvailable = false
    var keyboardBacklightOn = false
    var showHiddenFiles = false
    var desktopIconsHidden = false
    var externalVolumes: [String] = []
    var trashItemCount: Int?
    var confirmEmptyTrash = false
    var status: Status?

    @ObservationIgnored private let backlight = KeyboardBacklight()
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    private static let backlightLevelKey = "keyboardBacklightLevel"

    init() {
        keyboardBacklightAvailable = backlight.isAvailable
    }

    func refresh() {
        keyboardBacklightAvailable = backlight.isAvailable
        keyboardBacklightOn = (backlight.brightness ?? 0) > 0.01
        showHiddenFiles = FinderPrefs.showsHiddenFiles
        desktopIconsHidden = !FinderPrefs.desktopIconsVisible
        externalVolumes = Volumes.external().map(\.lastPathComponent)
        trashItemCount = TrashInfo.itemCount   // nil unless the app has Files and Folders access
    }

    // MARK: Actions

    func setKeyboardBacklight(_ on: Bool) {
        let defaults = UserDefaults.standard
        if on {
            let level = (defaults.object(forKey: Self.backlightLevelKey) as? Float) ?? 0.6
            let ok = backlight.setBrightness(level)
            keyboardBacklightOn = ok
            if !ok { report("kb", "백라이트를 켜지 못했어요", error: true) }
        } else {
            if let current = backlight.brightness, current > 0.01 {
                defaults.set(current, forKey: Self.backlightLevelKey)
            }
            let ok = backlight.setBrightness(0)
            keyboardBacklightOn = !ok
            if !ok { report("kb", "백라이트를 끄지 못했어요", error: true) }
        }
    }

    func lockScreen() {
        do {
            try ScreenControl.lockScreen()
        } catch {
            report("lock", error.localizedDescription, error: true)
        }
    }

    func startScreenSaver() {
        ScreenControl.startScreenSaver()
    }

    func sleepDisplay() {
        do {
            try ScreenControl.sleepDisplay()
        } catch {
            report("display", error.localizedDescription, error: true)
        }
    }

    func emptyTrash() {
        confirmEmptyTrash = false
        do {
            try TrashInfo.empty()
            trashItemCount = TrashInfo.itemCount
            report("trash", "휴지통을 비웠어요", error: false)
        } catch {
            report("trash", error.localizedDescription, error: true)
        }
    }

    func ejectAll() {
        do {
            let count = try Volumes.ejectAll()
            externalVolumes = Volumes.external().map(\.lastPathComponent)
            report("eject", count == 0 ? "추출할 디스크가 없어요" : "디스크 \(count)개를 추출했어요", error: false)
        } catch {
            externalVolumes = Volumes.external().map(\.lastPathComponent)
            report("eject", error.localizedDescription, error: true)
        }
    }

    func setShowHiddenFiles(_ on: Bool) {
        showHiddenFiles = on
        FinderPrefs.set("AppleShowAllFiles", on)
        restartFinder(reportingAs: "hidden")
    }

    func setDesktopIconsHidden(_ hidden: Bool) {
        desktopIconsHidden = hidden
        FinderPrefs.set("CreateDesktop", !hidden)
        restartFinder(reportingAs: "desktop")
    }

    private func restartFinder(reportingAs id: String) {
        do {
            try FinderPrefs.restartFinder()
            report(id, "Finder를 다시 시작했어요", error: false)
        } catch {
            report(id, error.localizedDescription, error: true)
        }
    }

    private func report(_ id: String, _ text: String, error: Bool) {
        status = Status(id: id, text: text, isError: error)
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(error ? 5 : 2.5))
            guard !Task.isCancelled else { return }
            if self?.status?.id == id { self?.status = nil }
        }
    }
}
