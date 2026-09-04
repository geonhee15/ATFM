import Foundation
import Observation

struct ChecklistItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var isDone: Bool
    var createdAt: Date
    var doneAt: Date?
}

/// A tiny to-do list persisted as JSON in ~/Library/Application Support/ATFM/checklist.json.
@MainActor
@Observable
final class ChecklistStore {
    private(set) var items: [ChecklistItem] = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("checklist.json")
        load()
    }

    var activeItems: [ChecklistItem] { items.filter { !$0.isDone } }
    var doneItems: [ChecklistItem] { items.filter(\.isDone).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) } }

    // MARK: Mutations

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(ChecklistItem(id: UUID(), text: trimmed, isDone: false, createdAt: Date(), doneAt: nil))
        scheduleSave()
    }

    func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        items[index].doneAt = items[index].isDone ? Date() : nil
        scheduleSave()
    }

    func update(_ id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if trimmed.isEmpty {
            items.remove(at: index)
        } else {
            items[index].text = trimmed
        }
        scheduleSave()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearDone() {
        items.removeAll(where: \.isDone)
        scheduleSave()
    }

    func removeAll() {
        items = []
        scheduleSave()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ChecklistItem].self, from: data)) ?? []
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = items
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
