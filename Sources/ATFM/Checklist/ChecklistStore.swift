import Foundation
import Observation

struct ChecklistItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var isDone: Bool
    var createdAt: Date
    var doneAt: Date?
    /// "yyyy-MM-dd" of the archive bucket; nil while the item is on the active list.
    var archiveDay: String? = nil
    var archivedAt: Date? = nil

    var isArchived: Bool { archiveDay != nil }
}

struct ArchiveDay: Identifiable {
    let day: String
    let date: Date
    let items: [ChecklistItem]
    var id: String { day }
    var doneCount: Int { items.filter(\.isDone).count }
    var openCount: Int { items.count - doneCount }
}

/// To-do list with a date-keyed archive, persisted as JSON in ~/Library/Application Support/ATFM/checklist.json.
@MainActor
@Observable
final class ChecklistStore {
    private(set) var items: [ChecklistItem] = []
    /// Keep unfinished items on the list at the daily rollover instead of archiving them.
    var carryOverUnfinished: Bool {
        didSet { UserDefaults.standard.set(carryOverUnfinished, forKey: Self.carryOverKey) }
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rolloverTimer: Timer?
    private static let carryOverKey = "checklistCarryOverUnfinished"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("checklist.json")
        carryOverUnfinished = UserDefaults.standard.bool(forKey: Self.carryOverKey)
        load()
        archiveYesterdayIfNeeded()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.archiveYesterdayIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }

    // MARK: Derived lists

    var activeItems: [ChecklistItem] { items.filter { !$0.isArchived && !$0.isDone } }
    var doneItems: [ChecklistItem] {
        items.filter { !$0.isArchived && $0.isDone }.sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }
    var currentItems: [ChecklistItem] { items.filter { !$0.isArchived } }
    var archivedCount: Int { items.filter(\.isArchived).count }

    var archiveDays: [ArchiveDay] {
        var buckets: [String: [ChecklistItem]] = [:]
        for item in items where item.isArchived {
            buckets[item.archiveDay!, default: []].append(item)
        }
        return buckets.map { day, list in
            ArchiveDay(day: day, date: Self.dayFormatter.date(from: day) ?? .distantPast,
                       items: list.sorted { $0.createdAt < $1.createdAt })
        }
        .sorted { $0.day > $1.day }
    }

    static func dayString(for date: Date) -> String { dayFormatter.string(from: date) }

    // MARK: Active list mutations

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
        items.removeAll { !$0.isArchived && $0.isDone }
        scheduleSave()
    }

    func removeAllCurrent() {
        items.removeAll { !$0.isArchived }
        scheduleSave()
    }

    // MARK: Archive

    /// Manual archive of a finished item into today's bucket.
    func archive(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isDone, !items[index].isArchived else { return }
        items[index].archiveDay = Self.dayString(for: Date())
        items[index].archivedAt = Date()
        scheduleSave()
    }

    func archiveAllDone() {
        let today = Self.dayString(for: Date())
        for index in items.indices where !items[index].isArchived && items[index].isDone {
            items[index].archiveDay = today
            items[index].archivedAt = Date()
        }
        scheduleSave()
    }

    /// Daily rollover: everything created before today moves into the bucket of the day it was made.
    func archiveYesterdayIfNeeded() {
        let todayStart = Calendar.current.startOfDay(for: Date())
        var changed = false
        for index in items.indices where !items[index].isArchived && items[index].createdAt < todayStart {
            if carryOverUnfinished && !items[index].isDone { continue }
            items[index].archiveDay = Self.dayString(for: items[index].createdAt)
            items[index].archivedAt = Date()
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Brings an archived item back to today's list (keeps its done state).
    func restore(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isArchived else { return }
        items[index].archiveDay = nil
        items[index].archivedAt = nil
        items[index].createdAt = Date()
        scheduleSave()
    }

    func removeArchive(day: String) {
        items.removeAll { $0.archiveDay == day }
        scheduleSave()
    }

    func removeAllArchived() {
        items.removeAll(where: \.isArchived)
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
