import AppKit
import Observation

/// Global shortcuts for 빠른 툴: defaults ⌘⇧1 (text) / ⌘⇧2 (color), user-editable, resettable.
@MainActor
@Observable
final class ToolHotkeys {
    enum Action: String, CaseIterable, Identifiable {
        case captureText, pickColor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .captureText: return "화면 텍스트 복사"
            case .pickColor: return "화면 색상 추출"
            }
        }

        var defaultCombo: KeyCombo {
            switch self {
            case .captureText: return KeyCombo(keyCode: 18, flags: [.command, .shift])   // ⌘⇧1
            case .pickColor: return KeyCombo(keyCode: 19, flags: [.command, .shift])     // ⌘⇧2
            }
        }
    }

    private(set) var combos: [Action: KeyCombo]
    private(set) var recording: Action?
    private(set) var message: String?

    @ObservationIgnored var handlers: [Action: () -> Void] = [:]
    /// Makes the bubble the key window so the recorder sees key presses (set by AppDelegate).
    @ObservationIgnored var focusForRecording: (() -> Void)?
    @ObservationIgnored private var registrations: [Action: UInt32] = [:]
    @ObservationIgnored private var monitor: Any?

    private static let defaultsKey = "toolHotkeys"

    init() {
        var loaded: [Action: KeyCombo] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (raw, combo) in stored {
                if let action = Action(rawValue: raw) { loaded[action] = combo }
            }
        }
        for action in Action.allCases where loaded[action] == nil {
            loaded[action] = action.defaultCombo
        }
        combos = loaded
    }

    func combo(for action: Action) -> KeyCombo {
        combos[action] ?? action.defaultCombo
    }

    func isDefault(_ action: Action) -> Bool {
        combo(for: action) == action.defaultCombo
    }

    var allDefault: Bool {
        Action.allCases.allSatisfy(isDefault)
    }

    // MARK: Registration

    func registerAll() {
        unregisterAll()
        var problems: [String] = []
        for action in Action.allCases {
            let combo = combo(for: action)
            switch HotkeyCenter.shared.register(combo, action: { [weak self] in self?.handlers[action]?() }) {
            case .success(let id):
                registrations[action] = id
            case .failure(let error):
                problems.append("\(combo.display) (\(action.title)): \(error.message)")
            }
        }
        message = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    func unregisterAll() {
        for (_, id) in registrations { HotkeyCenter.shared.unregister(id) }
        registrations.removeAll()
    }

    // MARK: Editing

    @discardableResult
    func set(_ combo: KeyCombo, for action: Action) -> Bool {
        if let other = Action.allCases.first(where: { $0 != action && self.combo(for: $0) == combo }) {
            message = "\(combo.display)는 이미 '\(other.title)'에 쓰고 있어요"
            registerAll()
            return false
        }
        combos[action] = combo
        save()
        registerAll()
        return true
    }

    func reset(_ action: Action) {
        set(action.defaultCombo, for: action)
    }

    func resetAll() {
        for action in Action.allCases { combos[action] = action.defaultCombo }
        save()
        registerAll()
    }

    private func save() {
        var stored: [String: KeyCombo] = [:]
        for (action, combo) in combos { stored[action.rawValue] = combo }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Recording a new combo

    func beginRecording(_ action: Action) {
        if recording != nil { stopMonitor() }
        recording = action
        message = nil
        unregisterAll()                 // pressing the current combo must not fire the tool mid-edit
        focusForRecording?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording != nil else { return event }
            self.handle(event)
            return nil
        }
    }

    func cancelRecording() {
        guard recording != nil else { return }
        stopMonitor()
        registerAll()
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording else { return }
        let flags = event.modifierFlags.intersection(KeyCombo.modifierMask)
        if event.keyCode == 53, flags.isEmpty {      // Esc
            cancelRecording()
            return
        }
        let combo = KeyCombo(keyCode: event.keyCode, flags: flags)
        guard combo.isUsable else {
            message = "⌘ · ⌃ · ⌥ 중 하나를 함께 누르거나 F키를 써 주세요"
            return
        }
        stopMonitor()
        set(combo, for: action)
    }

    private func stopMonitor() {
        recording = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
