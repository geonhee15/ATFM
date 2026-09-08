import CoreServices
import Foundation

struct DictionaryEntry: Identifiable, Equatable {
    let id = UUID()
    let headword: String
    let text: String
}

/// macOS DictionaryServices wrapper. `DCSCopyTextDefinition` is public; the record functions that
/// return every homonym are private but stable, so they are resolved with dlsym and every call is
/// guarded — if a symbol is missing we fall back to the single-definition API.
final class SystemDictionary {
    enum Kind: String, CaseIterable {
        case koreanEnglish = "com.apple.dictionary.ko-en.NewAce"   // 뉴에이스 영한 / 한영
        case korean = "com.apple.dictionary.ko.NewAce"             // 뉴에이스 국어사전
        case englishNOAD = "com.apple.dictionary.NOAD"
        case englishODE = "com.apple.dictionary.ODE"

        var title: String {
            switch self {
            case .koreanEnglish: return "뉴에이스 영한 · 한영"
            case .korean: return "뉴에이스 국어사전"
            case .englishNOAD: return "New Oxford American"
            case .englishODE: return "Oxford Dictionary of English"
            }
        }
    }

    static let shared = SystemDictionary()

    private typealias CopyAvailable = @convention(c) () -> Unmanaged<CFSet>?
    private typealias GetIdentifier = @convention(c) (DCSDictionary) -> Unmanaged<CFString>?
    private typealias CopyRecords = @convention(c) (DCSDictionary, CFString, CFIndex, CFIndex) -> Unmanaged<CFArray>?
    private typealias RecordHeadword = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias RecordCopyData = @convention(c) (CFTypeRef, CFIndex) -> Unmanaged<CFString>?

    private let copyAvailable: CopyAvailable?
    private let getIdentifier: GetIdentifier?
    private let copyRecords: CopyRecords?
    private let recordHeadword: RecordHeadword?
    private let recordCopyData: RecordCopyData?
    private var dictionaries: [Kind: DCSDictionary] = [:]

    private init() {
        let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: type)
        }
        copyAvailable = load("DCSCopyAvailableDictionaries", as: CopyAvailable.self)
        getIdentifier = load("DCSDictionaryGetIdentifier", as: GetIdentifier.self)
        copyRecords = load("DCSCopyRecordsForSearchString", as: CopyRecords.self)
        recordHeadword = load("DCSRecordGetHeadword", as: RecordHeadword.self)
        recordCopyData = load("DCSRecordCopyData", as: RecordCopyData.self)
        indexDictionaries()
    }

    private func indexDictionaries() {
        guard let copyAvailable, let getIdentifier, let set = copyAvailable()?.takeRetainedValue() as? Set<AnyHashable> else { return }
        for item in set {
            let dictionary = item as AnyObject as! DCSDictionary
            guard let identifier = getIdentifier(dictionary)?.takeUnretainedValue() as String?,
                  let kind = Kind(rawValue: identifier) else { continue }
            dictionaries[kind] = dictionary
        }
    }

    func isAvailable(_ kind: Kind) -> Bool {
        dictionaries[kind] != nil
    }

    /// True once a definition actually comes back (dictionaries are downloaded on demand by Dictionary.app).
    func isInstalled(_ kind: Kind) -> Bool {
        let probe: String
        switch kind {
        case .koreanEnglish, .englishNOAD, .englishODE: probe = "apple"
        case .korean: probe = "사과"
        }
        return definition(of: probe, in: kind) != nil
    }

    /// Single best definition (public API).
    func definition(of word: String, in kind: Kind) -> String? {
        guard let dictionary = dictionaries[kind] else { return nil }
        let term = word as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(term))
        return DCSCopyTextDefinition(dictionary, term, range)?.takeRetainedValue() as String?
    }

    /// Every matching record (homonyms) as plain text; falls back to `definition(of:)`.
    func entries(for word: String, in kind: Kind, prefix: Bool = false, limit: Int = 0) -> [DictionaryEntry] {
        guard let dictionary = dictionaries[kind] else { return [] }
        if let copyRecords, let recordHeadword, let recordCopyData,
           let records = copyRecords(dictionary, word as CFString, prefix ? 1 : 0, limit)?.takeRetainedValue() as? [AnyObject] {
            var seen = Set<String>()
            var result: [DictionaryEntry] = []
            for record in records {
                let headword = (recordHeadword(record)?.takeUnretainedValue() as String?) ?? word
                let text = (recordCopyData(record, 3)?.takeRetainedValue() as String?)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty, seen.insert(headword + "|" + text.prefix(40)).inserted else { continue }
                result.append(DictionaryEntry(headword: headword, text: text))
            }
            if !result.isEmpty { return result }
        }
        if let text = definition(of: word, in: kind) {
            return [DictionaryEntry(headword: word, text: text.trimmingCharacters(in: .whitespacesAndNewlines))]
        }
        return []
    }

    /// Headwords starting with `word` (for "did you mean" chips).
    func suggestions(for word: String, in kind: Kind, limit: Int = 8) -> [String] {
        guard let dictionary = dictionaries[kind], let copyRecords, let recordHeadword,
              let records = copyRecords(dictionary, word as CFString, 1, limit * 3)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var out: [String] = []
        for record in records {
            guard let headword = recordHeadword(record)?.takeUnretainedValue() as String? else { continue }
            let clean = headword.trimmingCharacters(in: .whitespaces)
            if !out.contains(clean), clean.caseInsensitiveCompare(word) != .orderedSame { out.append(clean) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Adds line breaks around sense numbers / examples so the NewAce one-liners read like an entry.
    static func prettify(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"\s*▸\s*"#, "\n  ▸ "),
            (#"(?<=\S)\s*([①-⑳])"#, "\n$1 "),
            (#"(?<=[^\d\s])\s*(\d{1,2})\.(?=\S)"#, "\n$1. "),
            (#"\s*(\{[^}]{1,20}\})"#, " $1"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.replacingOccurrences(of: "\n\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
