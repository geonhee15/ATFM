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
    /// Optional deadline (date + time).
    var dueAt: Date? = nil

    var isArchived: Bool { archiveDay != nil }
    var isOverdue: Bool { !isDone && (dueAt.map { $0 < Date() } ?? false) }
}

enum Deadline {
    /// "오늘 18:00", "내일 09:00", "금요일 14:00", "9월 12일 18:00", "지난주 …" style label.
    static func label(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        if calendar.isDateInToday(date) { return "오늘 " + time }
        if calendar.isDateInTomorrow(date) { return "내일 " + time }
        if calendar.isDateInYesterday(date) { return "어제 " + time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days > 1, days < 7 { return date.formatted(.dateTime.weekday(.wide)) + " " + time }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month().day()) + " " + time
        }
        return date.formatted(.dateTime.year().month().day()) + " " + time
    }

    /// Quick presets offered in the picker.
    static func presets(now: Date = Date()) -> [(title: String, date: Date)] {
        let calendar = Calendar.current
        func at(_ base: Date, hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }
        var list: [(String, Date)] = []
        let today18 = at(now, hour: 18)
        if today18 > now { list.append(("오늘 18:00", today18)) }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        list.append(("내일 09:00", at(tomorrow, hour: 9)))
        list.append(("내일 18:00", at(tomorrow, hour: 18)))
        let weekday = calendar.component(.weekday, from: now)   // 1 = Sunday
        let daysToFriday = ((6 - weekday) + 7) % 7
        let friday = calendar.date(byAdding: .day, value: daysToFriday == 0 ? 7 : daysToFriday, to: now)!
        list.append(("이번 주 금요일 18:00", at(friday, hour: 18)))
        let daysToMonday = ((2 - weekday) + 7) % 7
        let monday = calendar.date(byAdding: .day, value: daysToMonday == 0 ? 7 : daysToMonday, to: now)!
        list.append(("다음 주 월요일 09:00", at(monday, hour: 9)))
        return list.map { (title: $0.0, date: $0.1) }
    }
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
    /// Show the active list ordered by deadline (items without one last).
    var sortByDue: Bool {
        didSet { UserDefaults.standard.set(sortByDue, forKey: Self.sortByDueKey) }
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rolloverTimer: Timer?
    private static let carryOverKey = "checklistCarryOverUnfinished"
    private static let sortByDueKey = "checklistSortByDue"

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
        sortByDue = UserDefaults.standard.bool(forKey: Self.sortByDueKey)
        load()
        archiveYesterdayIfNeeded()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.archiveYesterdayIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }

    // MARK: Derived lists

    var activeItems: [ChecklistItem] {
        let list = items.filter { !$0.isArchived && !$0.isDone }
        guard sortByDue else { return list }
        return list.sorted { a, b in
            switch (a.dueAt, b.dueAt) {
            case let (x?, y?): return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.createdAt < b.createdAt
            }
        }
    }
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

    func add(_ text: String, dueAt: Date? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(ChecklistItem(id: UUID(), text: trimmed, isDone: false, createdAt: Date(), doneAt: nil, dueAt: dueAt))
        scheduleSave()
    }

    func setDue(_ id: UUID, _ date: Date?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].dueAt = date
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
