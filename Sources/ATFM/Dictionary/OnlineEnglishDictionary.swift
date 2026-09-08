import Foundation

/// dictionaryapi.dev — free, keyless English-English definitions with IPA.
struct OnlineEnglishEntry: Equatable {
    struct Sense: Equatable, Identifiable {
        let id = UUID()
        let partOfSpeech: String
        let definitions: [(definition: String, example: String?)]
        static func == (a: Sense, b: Sense) -> Bool { a.id == b.id }
    }
    let word: String
    let phonetic: String?
    let senses: [Sense]
}

enum OnlineEnglishDictionary {
    static func fetch(_ word: String) async -> OnlineEnglishEntry? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var phonetic: String?
        var senses: [OnlineEnglishEntry.Sense] = []
        for entry in array {
            if phonetic == nil {
                phonetic = entry["phonetic"] as? String
                    ?? (entry["phonetics"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.first { !$0.isEmpty }
            }
            for meaning in entry["meanings"] as? [[String: Any]] ?? [] {
                let pos = meaning["partOfSpeech"] as? String ?? ""
                let defs = (meaning["definitions"] as? [[String: Any]] ?? []).prefix(4).compactMap { d -> (String, String?)? in
                    guard let text = d["definition"] as? String else { return nil }
                    return (text, d["example"] as? String)
                }
                guard !defs.isEmpty else { continue }
                senses.append(.init(partOfSpeech: pos, definitions: defs.map { (definition: $0.0, example: $0.1) }))
            }
            if senses.count >= 5 { break }
        }
        guard !senses.isEmpty else { return nil }
        return OnlineEnglishEntry(word: (array.first?["word"] as? String) ?? trimmed, phonetic: phonetic, senses: Array(senses.prefix(5)))
    }
}
