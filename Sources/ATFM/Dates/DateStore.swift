import Foundation
import Observation
import SwiftUI

/// One calendar event and/or D-day. `showsInCalendar` / `showsInDday` decide where it appears.
struct DateEntry: Identifiable, Codable, Equatable {
    enum Repeat: String, Codable, CaseIterable, Identifiable {
        case none, monthly, yearly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "반복 없음"
            case .monthly: return "매월"
            case .yearly: return "매년"
            }
        }
    }

    var id: UUID = UUID()
    var title: String
    var year: Int
    var month: Int
    var day: Int
    var hour: Int? = nil
    var minute: Int? = nil
    var note: String = ""
    var colorIndex: Int = 0
    var showsInCalendar: Bool = true
    var showsInDday: Bool = false
    var repeatRule: Repeat = .none
    var createdAt: Date = Date()
    /// Which number the D-day row shows big (nil = countdown). Optional so old files still decode.
    var ddayStyle: DDayStyle? = nil
    /// "처음부터 D+": count the start day itself as day 1 (couple-app style).
    var countsStartAsOne: Bool? = nil

    enum DDayStyle: String, Codable, CaseIterable, Identifiable {
        case countdown, elapsed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .countdown: return "기념일까지 D-"
            case .elapsed: return "처음부터 D+"
            }
        }
    }

    var style: DDayStyle { ddayStyle ?? .countdown }
    var startsAtOne: Bool { countsStartAsOne ?? false }

    static let palette: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 0.95),   // blue
        Color(red: 0.95, green: 0.40, blue: 0.40),   // red
        Color(red: 0.98, green: 0.62, blue: 0.25),   // orange
        Color(red: 0.35, green: 0.72, blue: 0.45),   // green
        Color(red: 0.65, green: 0.45, blue: 0.95),   // purple
        Color(red: 0.95, green: 0.50, blue: 0.75),   // pink
        Color(red: 0.55, green: 0.55, blue: 0.60),   // gray
    ]

    var color: Color { Self.palette[max(0, min(colorIndex, Self.palette.count - 1))] }

    var components: DateComponents { DateComponents(year: year, month: month, day: day, hour: hour, minute: minute) }

    var date: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    var hasTime: Bool { hour != nil }

    var timeText: String? {
        guard let hour, let minute else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// Does this entry land on `day` (a start-of-day Date), honoring repeats?
    func occurs(on target: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.year, .month, .day], from: target)
        switch repeatRule {
        case .none: return c.year == year && c.month == month && c.day == day
        case .monthly: return c.day == day && target >= date
        case .yearly: return c.month == month && c.day == day && target >= date
        }
    }
}

/// What the D-day list shows for an entry.
struct DDayInfo: Identifiable {
    let entry: DateEntry
    let label: String        // "D-12", "D-Day", "D+120"
    let daysUntil: Int       // days to the next occurrence; negative = past (non-repeating)
    let isElapsed: Bool      // big number counts up from the start (blue) instead of down (red)
    let secondary: String
    var id: UUID { entry.id }
    var isToday: Bool { daysUntil == 0 && !isElapsed }
}

@MainActor
@Observable
final class DateStore {
    private(set) var entries: [DateEntry] = []
    var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    var visibleMonth: Date = Calendar.current.startOfDay(for: Date())

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("dates.json")
        load()
    }

    // MARK: Editing

    func add(_ entry: DateEntry) {
        entries.append(entry)
        scheduleSave()
    }

    func update(_ entry: DateEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return add(entry) }
        entries[index] = entry
        scheduleSave()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Calendar queries

    func events(on day: Date) -> [DateEntry] {
        let start = Calendar.current.startOfDay(for: day)
        return entries.filter { $0.showsInCalendar && $0.occurs(on: start) }
            .sorted { ($0.hour ?? -1, $0.minute ?? -1, $0.title) < ($1.hour ?? -1, $1.minute ?? -1, $1.title) }
    }

    /// 42 cells (6 weeks) starting on the Sunday on/before the 1st of `visibleMonth`.
    func monthGrid() -> [Date] {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: visibleMonth)
        guard let first = calendar.date(from: comps) else { return [] }
        let weekday = calendar.component(.weekday, from: first)   // 1 = Sunday
        guard let gridStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: first) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    func shiftMonth(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = Calendar.current.startOfDay(for: next)
        }
    }

    func goToday() {
        let today = Calendar.current.startOfDay(for: Date())
        visibleMonth = today
        selectedDay = today
    }

    // MARK: D-days

    func ddays(today: Date = Date()) -> [DDayInfo] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: today)
        let infos = entries.filter(\.showsInDday).map { entry -> DDayInfo in
            let target = Self.nextOccurrence(of: entry, from: start, calendar: calendar)
            let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
            let sinceStart = (calendar.dateComponents([.day], from: entry.date, to: start).day ?? 0) + (entry.startsAtOne ? 1 : 0)
            let label: String
            let elapsed: Bool
            if entry.style == .elapsed, sinceStart >= (entry.startsAtOne ? 1 : 0) {
                label = "D+\(sinceStart)"
                elapsed = true
            } else if days == 0 {
                label = "D-Day"; elapsed = false
            } else if days > 0 {
                label = "D-\(days)"; elapsed = false
            } else {
                label = "D+\(-days)"; elapsed = true          // non-repeating date that already passed
            }
            return DDayInfo(entry: entry, label: label, daysUntil: days, isElapsed: elapsed,
                            secondary: Self.secondaryText(for: entry, target: target, today: start, daysUntil: days,
                                                          sinceStart: sinceStart, calendar: calendar))
        }
        // Upcoming (D-Day first, then soonest) before past D+ items (most recent first).
        return infos.sorted {
            if ($0.daysUntil >= 0) != ($1.daysUntil >= 0) { return $0.daysUntil >= 0 }
            return $0.daysUntil >= 0 ? $0.daysUntil < $1.daysUntil : $0.daysUntil > $1.daysUntil
        }
    }

    static func nextOccurrence(of entry: DateEntry, from today: Date, calendar: Calendar) -> Date {
        let base = entry.date
        switch entry.repeatRule {
        case .none:
            return base
        case .yearly:
            let year = calendar.component(.year, from: today)
            for y in [year, year + 1] {
                if let candidate = calendar.date(from: DateComponents(year: y, month: entry.month, day: entry.day)), candidate >= today, candidate >= base {
                    return candidate
                }
            }
            return base
        case .monthly:
            let comps = calendar.dateComponents([.year, .month], from: today)
            for offset in 0...2 {
                if let monthStart = calendar.date(byAdding: .month, value: offset, to: calendar.date(from: comps) ?? today),
                   let candidate = calendar.date(from: DateComponents(year: calendar.component(.year, from: monthStart),
                                                                       month: calendar.component(.month, from: monthStart),
                                                                       day: entry.day)),
                   candidate >= today, candidate >= base {
                    return candidate
                }
            }
            return base
        }
    }

    private static func secondaryText(for entry: DateEntry, target: Date, today: Date, daysUntil: Int,
                                      sinceStart: Int, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 (E)"
        let countdown = daysUntil == 0 ? "오늘" : daysUntil > 0 ? "D-\(daysUntil)" : "D+\(-daysUntil)"
        let elapsed = entry.style == .elapsed
        switch entry.repeatRule {
        case .none:
            var parts = [f.string(from: entry.date) + (entry.timeText.map { " \($0)" } ?? "")]
            if elapsed, daysUntil > 0 { parts.append("아직 \(countdown)") }
            if !elapsed, daysUntil < 0 { parts.append("처음부터 D+\(sinceStart)") }
            return parts.joined(separator: " · ")
        case .yearly:
            let years = calendar.component(.year, from: target) - entry.year
            var parts = ["매년 \(entry.month)월 \(entry.day)일"]
            if years > 0 { parts.append("\(years)주년") }
            if elapsed { parts.insert("다음 기념일 \(countdown)", at: 0) } else if sinceStart > 0 { parts.append("처음부터 D+\(sinceStart)") }
            return parts.joined(separator: " · ")
        case .monthly:
            var parts = ["매월 \(entry.day)일"]
            if elapsed { parts.insert("다음 \(countdown)", at: 0) } else if sinceStart > 0 { parts.append("처음부터 D+\(sinceStart)") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([DateEntry].self, from: data)) ?? []
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    func flush() {
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
