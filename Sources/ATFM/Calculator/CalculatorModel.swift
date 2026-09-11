import AppKit
import Observation

struct CalcEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    let expression: String
    let result: String
}

@MainActor
@Observable
final class CalculatorModel {
    var input = "" {
        didSet { evaluateLive() }
    }
    private(set) var liveResult: String?
    private(set) var liveError: String?
    private(set) var history: [CalcEntry] = []
    var degrees: Bool {
        didSet {
            UserDefaults.standard.set(degrees, forKey: Self.degreesKey)
            evaluateLive()
        }
    }
    private(set) var copied = false

    @ObservationIgnored private var ans: Double = 0
    private static let degreesKey = "calcDegrees"
    private static let historyKey = "calcHistory"

    init() {
        degrees = UserDefaults.standard.object(forKey: Self.degreesKey) as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([CalcEntry].self, from: data) {
            history = saved
        }
    }

    private func evaluateLive() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { liveResult = nil; liveError = nil; return }
        var engine = CalcEngine(degrees: degrees, ans: ans)
        do {
            liveResult = CalcEngine.format(try engine.evaluate(text))
            liveError = nil
        } catch {
            liveResult = nil
            liveError = error.localizedDescription
        }
    }

    /// Enter: push "expr = result" to history and make the result `ans`.
    func commit() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var engine = CalcEngine(degrees: degrees, ans: ans)
        guard let value = try? engine.evaluate(text) else { return }
        ans = value
        let formatted = CalcEngine.format(value)
        history.insert(CalcEntry(expression: text, result: formatted), at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
        save()
        input = ""
    }

    func insert(_ text: String) { input += text }

    func backspace() {
        guard !input.isEmpty else { return }
        input.removeLast()
    }

    func clear() { input = "" }

    func useEntry(_ entry: CalcEntry, expression: Bool) {
        input = expression ? entry.expression : entry.result.replacingOccurrences(of: ",", with: "")
    }

    func clearHistory() {
        history = []
        save()
    }

    func copyResult() {
        guard let text = liveResult ?? history.first?.result else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text.replacingOccurrences(of: ",", with: ""), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { self?.copied = false }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
}
