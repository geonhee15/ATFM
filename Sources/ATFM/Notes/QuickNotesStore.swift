import Foundation
import Observation

struct QuickNote: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First non-empty line, used as the chip label.
    var title: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "새 메모" : line
    }
}

/// 미니 메모: a handful of scratch notes, autosaved to notes.json (newest first, no reordering on edit).
@MainActor
@Observable
final class QuickNotesStore {
    private(set) var notes: [QuickNote] = []
    var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: Self.selectedKey) }
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private static let selectedKey = "quickNoteSelected"

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("notes.json")
        load()
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey), let id = UUID(uuidString: raw),
           notes.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = notes.first?.id
        }
        if notes.isEmpty { addNote() }
    }

    var selected: QuickNote? {
        notes.first { $0.id == selectedID }
    }

    var selectedText: String {
        get { selected?.text ?? "" }
        set { update(text: newValue) }
    }

    @discardableResult
    func addNote() -> QuickNote {
        // Reuse an existing empty note instead of piling up blanks.
        if let empty = notes.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            selectedID = empty.id
            return empty
        }
        let note = QuickNote()
        notes.insert(note, at: 0)
        selectedID = note.id
        scheduleSave()
        return note
    }

    func update(text: String) {
        guard let index = notes.firstIndex(where: { $0.id == selectedID }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = Date()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: index)
        if selectedID == id {
            selectedID = notes[safe: min(index, notes.count - 1)]?.id
        }
        if notes.isEmpty { addNote() }
        scheduleSave()
    }

    func select(_ id: UUID) {
        selectedID = id
    }

    /// Synchronous write for app termination.
    func flush() {
        saveTask?.cancel()
        write(notes)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        notes = (try? decoder.decode([QuickNote].self, from: data)) ?? []
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = notes
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: url)
        }
    }

    private func write(_ snapshot: [QuickNote]) {
        Self.write(snapshot, to: fileURL)
    }

    nonisolated private static func write(_ snapshot: [QuickNote], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
