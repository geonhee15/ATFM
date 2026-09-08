import AppKit
import Observation

/// 사전 tab: English (영한 + online 영영), Korean (국어), and the periodic table.
@MainActor
@Observable
final class DictionaryHub {
    enum Section: String, CaseIterable, Identifiable {
        case english, korean, periodic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .english: return "영어"
            case .korean: return "국어"
            case .periodic: return "주기율표"
            }
        }
    }

    var section: Section {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey) }
    }
    var query = ""
    private(set) var searched = ""
    private(set) var entries: [DictionaryEntry] = []
    private(set) var suggestions: [String] = []
    private(set) var online: OnlineEnglishEntry?
    private(set) var onlineLoading = false
    private(set) var englishEnglish: [DictionaryEntry] = []
    private(set) var recent: [Section: [String]]
    var elementQuery = ""
    var selectedElement: ChemicalElement?

    let koreanEnglishInstalled: Bool
    let koreanInstalled: Bool
    let englishEnglishKind: SystemDictionary.Kind?

    @ObservationIgnored private var onlineTask: Task<Void, Never>?
    private static let sectionKey = "dictionarySection"
    private static let recentKey = "dictionaryRecent"

    init() {
        section = Section(rawValue: UserDefaults.standard.string(forKey: Self.sectionKey) ?? "") ?? .english
        let stored = UserDefaults.standard.dictionary(forKey: Self.recentKey) as? [String: [String]] ?? [:]
        var map: [Section: [String]] = [:]
        for (key, words) in stored { if let s = Section(rawValue: key) { map[s] = words } }
        recent = map
        let dictionary = SystemDictionary.shared
        koreanEnglishInstalled = dictionary.isInstalled(.koreanEnglish)
        koreanInstalled = dictionary.isInstalled(.korean)
        englishEnglishKind = [SystemDictionary.Kind.englishNOAD, .englishODE].first { dictionary.isInstalled($0) }
    }

    var recentForSection: [String] { recent[section] ?? [] }

    var currentKind: SystemDictionary.Kind { section == .korean ? .korean : .koreanEnglish }

    var currentInstalled: Bool { section == .korean ? koreanInstalled : koreanEnglishInstalled }

    func lookup(_ word: String? = nil) {
        let term = (word ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, section != .periodic else { return }
        query = term
        searched = term
        let dictionary = SystemDictionary.shared
        entries = dictionary.entries(for: term, in: currentKind)
        suggestions = entries.isEmpty ? dictionary.suggestions(for: term, in: currentKind) : []
        englishEnglish = []
        online = nil
        onlineTask?.cancel()
        if section == .english, Self.isLatin(term) {
            if let kind = englishEnglishKind {
                englishEnglish = dictionary.entries(for: term, in: kind, limit: 3)
            }
            // Online 영영 only when no offline English-English dictionary is installed.
            if englishEnglish.isEmpty {
                onlineLoading = true
                onlineTask = Task { [weak self] in
                    let result = await OnlineEnglishDictionary.fetch(term)
                    guard !Task.isCancelled, let self, self.searched == term else { return }
                    self.online = result
                    self.onlineLoading = false
                }
            } else {
                onlineLoading = false
            }
        } else {
            onlineLoading = false
        }
        remember(term)
    }

    func clear() {
        query = ""
        searched = ""
        entries = []
        suggestions = []
        online = nil
        englishEnglish = []
        onlineLoading = false
        onlineTask?.cancel()
    }

    /// Pre-fills the field with a single short word from the clipboard.
    func pasteIfWord() {
        guard query.isEmpty, let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard !text.isEmpty, text.count <= 24, !text.contains(where: \.isNewline), text.split(separator: " ").count <= 2,
              !text.contains("://") else { return }
        query = text
    }

    func openInDictionaryApp(_ word: String? = nil) {
        let term = (word ?? (searched.isEmpty ? query : searched)).trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "dict://\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openDictionaryApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Dictionary.app"))
    }

    private func remember(_ term: String) {
        var list = recent[section] ?? []
        list.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        list.insert(term, at: 0)
        if list.count > 8 { list.removeLast(list.count - 8) }
        recent[section] = list
        var stored: [String: [String]] = [:]
        for (key, words) in recent { stored[key.rawValue] = words }
        UserDefaults.standard.set(stored, forKey: Self.recentKey)
    }

    static func isLatin(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII || CharacterSet.punctuationCharacters.contains($0) }
    }

    // MARK: Periodic table

    var elementMatches: [ChemicalElement] {
        PeriodicTable.search(elementQuery)
    }

    func selectElement(_ element: ChemicalElement?) {
        selectedElement = element
    }
}
