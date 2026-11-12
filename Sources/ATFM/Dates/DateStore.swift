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
    /// Optional end of a multi-day span (inclusive). nil = single day. Optional so old files still decode.
    var endYear: Int? = nil
    var endMonth: Int? = nil
    var endDay: Int? = nil
    /// Optional end time ("15:00–16:30"); only used together with a start time. Optional so old files still decode.
    /// Single day: that same day, or the next morning when it is not after the start (23:00–01:00). Span: on the last day.
    var endHour: Int? = nil
    var endMinute: Int? = nil
    /// Which number the D-day row shows big (nil = countdown). Optional so old files still decode.
    var ddayStyle: DDayStyle? = nil
    /// "처음부터 D+": count the start day itself as day 1 (couple-app style).
    var countsStartAsOne: Bool? = nil
    /// Copy of this entry in an account calendar (Google etc.) through the Calendar app. nil = ATFM only.
    var mirror: CalendarMirror? = nil

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

    var hasEndTime: Bool { hour != nil && minute != nil && endHour != nil && endMinute != nil }

    /// A single-day entry whose end time is not after its start runs into the next morning.
    var endsNextDay: Bool {
        guard !isMultiDay, let hour, let minute, let endHour, let endMinute else { return false }
        return (endHour, endMinute) <= (hour, minute)
    }

    /// Inclusive end date; equals `date` for single-day entries.
    var endDate: Date {
        guard let endYear, let endMonth, let endDay,
              let end = Calendar.current.date(from: DateComponents(year: endYear, month: endMonth, day: endDay)),
              end > date else { return date }
        return end
    }

    var isMultiDay: Bool { endDate > date }

    /// Number of days in the span (1 for a single day).
    var spanDays: Int { (Calendar.current.dateComponents([.day], from: date, to: endDate).day ?? 0) + 1 }

    mutating func setEnd(_ end: Date?) {
        guard let end, Calendar.current.startOfDay(for: end) > date else { endYear = nil; endMonth = nil; endDay = nil; return }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: end)
        endYear = c.year; endMonth = c.month; endDay = c.day
    }

    var rangeText: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M/d"
        return "\(f.string(from: date))–\(f.string(from: endDate)) · \(spanDays)일간"
    }

    private static func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    /// "15:00", or "15:00–16:30" with an end time.
    var timeText: String? {
        guard let hour, let minute else { return nil }
        guard let endHour, let endMinute else { return Self.clock(hour, minute) }
        return "\(Self.clock(hour, minute))–\(Self.clock(endHour, endMinute))"
    }

    /// What the row of one day shows. A span starts on its first day ("09:00~"), ends on its last
    /// ("~18:00") and takes the whole day in between (nil = 종일).
    func timeText(on day: Date, calendar: Calendar = .current) -> String? {
        guard let hour, let minute else { return nil }
        guard isMultiDay else { return timeText }
        if isSpanStart(day, calendar: calendar) { return "\(Self.clock(hour, minute))~" }
        if isSpanEnd(day, calendar: calendar), let endHour, let endMinute { return "~\(Self.clock(endHour, endMinute))" }
        return nil
    }

    /// Does this entry land on `day` (a start-of-day Date), honoring repeats?
    func occurs(on target: Date, calendar: Calendar = .current) -> Bool {
        occurrenceStart(containing: target, calendar: calendar) != nil
    }

    /// Start date of the occurrence (single day or span) that contains `target`, if any.
    func occurrenceStart(containing target: Date, calendar: Calendar = .current) -> Date? {
        let span = spanDays - 1
        func contains(_ start: Date) -> Bool {
            guard start >= date, let end = calendar.date(byAdding: .day, value: span, to: start) else { return false }
            return target >= start && target <= end
        }
        switch repeatRule {
        case .none:
            return contains(date) ? date : nil
        case .yearly:
            let y = calendar.component(.year, from: target)
            for candidateYear in [y, y - 1] {
                if let start = calendar.date(from: DateComponents(year: candidateYear, month: month, day: day)), contains(start) { return start }
            }
            return nil
        case .monthly:
            let comps = calendar.dateComponents([.year, .month], from: target)
            for offset in [0, -1] {
                if let base = calendar.date(from: comps), let monthStart = calendar.date(byAdding: .month, value: offset, to: base),
                   let start = calendar.date(from: DateComponents(year: calendar.component(.year, from: monthStart),
                                                                 month: calendar.component(.month, from: monthStart), day: day)),
                   contains(start) { return start }
            }
            return nil
        }
    }

    func isSpanStart(_ target: Date, calendar: Calendar = .current) -> Bool {
        occurrenceStart(containing: target, calendar: calendar) == calendar.startOfDay(for: target)
    }

    func isSpanEnd(_ target: Date, calendar: Calendar = .current) -> Bool {
        guard let start = occurrenceStart(containing: target, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: spanDays - 1, to: start) else { return false }
        return end == calendar.startOfDay(for: target)
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

    /// Writes the account-calendar copies of entries that ask for one (`DateEntry.mirror`). nil = nothing is copied.
    @ObservationIgnored var mirrorBackend: CalendarMirrorBackend?
    /// Last thing that went wrong with a copy; the 날짜 tab shows it as a banner.
    private(set) var mirrorNotice: String?
    /// What the last "모두 올리기" did, so the 날짜 tab can report it and offer 되돌리기. Not saved: gone after a restart.
    private(set) var lastBulkMirror: BulkMirror?

    struct BulkMirror: Equatable {
        var calendarID: String
        /// Entries it linked: written, or still waiting after a failed write.
        var entryIDs: [UUID] = []
        var written = 0
        var failed = 0
        /// The whole batch stopped here (no calendar access, calendar gone).
        var stoppedBy: String? = nil
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("dates.json")
        load()
    }

    // MARK: Editing

    func add(_ entry: DateEntry) {
        var fresh = entry
        // A new entry never shares a copy with another one (복제 carries the original's link): it gets its own event.
        if let link = fresh.mirror { fresh.mirror = CalendarMirror(calendarID: link.calendarID) }
        entries.append(syncMirror(fresh, previous: nil))
        if fresh.mirror != nil { mirrorBackend?.mirrorLinksChanged() }
        scheduleSave()
    }

    func update(_ entry: DateEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return add(entry) }
        let previous = entries[index]
        entries[index] = syncMirror(entry, previous: previous)
        if previous.mirror != entries[index].mirror { mirrorBackend?.mirrorLinksChanged() }
        scheduleSave()
    }

    func delete(_ id: UUID) {
        let mirrored = entries.first(where: { $0.id == id })?.mirror != nil
        if let entry = entries.first(where: { $0.id == id }), let link = entry.mirror, link.isWritten {
            removeCopy(link, title: entry.title)
        }
        entries.removeAll { $0.id == id }
        if mirrored { mirrorBackend?.mirrorLinksChanged() }
        scheduleSave()
    }

    // MARK: Account-calendar copies

    /// Entries whose copy has not been written yet, or is behind after a failed write.
    var pendingMirrorCount: Int { entries.filter { $0.mirror?.needsWrite == true }.count }

    /// Identifiers of every copy ATFM wrote, so the imported-calendar overlay can skip them (no double rows).
    var mirroredEventIDs: Set<String> {
        var ids = Set<String>()
        for entry in entries {
            if let id = entry.mirror?.eventID { ids.insert(id) }
            if let id = entry.mirror?.externalID { ids.insert(id) }
        }
        return ids
    }

    func retryPendingMirrors() {
        guard let backend = mirrorBackend else { return }
        var failures = 0
        var lastError = ""
        for index in entries.indices {
            guard let link = entries[index].mirror, link.needsWrite else { continue }
            do {
                entries[index].mirror = try backend.writeMirror(MirrorEventSpec(entries[index]), link: link)
            } catch {
                failures += 1
                lastError = error.localizedDescription
            }
        }
        mirrorNotice = failures == 0 ? nil : "일정 \(failures)개를 아직 계정 캘린더에 못 올렸어요 · \(lastError)"
        backend.mirrorLinksChanged()
        scheduleSave()
    }

    func dismissMirrorNotice() { mirrorNotice = nil }

    /// Entries that live only in ATFM — what "모두 올리기" adds. D-day-only entries (not on the calendar) are opt-in.
    func entriesWithoutMirror(includingDdayOnly: Bool) -> [DateEntry] {
        entries.filter { $0.mirror == nil && ($0.showsInCalendar || includingDdayOnly) }
    }

    /// "모두 올리기": gives every entry that has no copy yet one in `calendarID`. Entries that already have a copy are left alone.
    @discardableResult
    func mirrorAll(to calendarID: String, includingDdayOnly: Bool) -> BulkMirror {
        var result = BulkMirror(calendarID: calendarID)
        guard let backend = mirrorBackend, !calendarID.isEmpty else { return result }
        var lastError = ""
        for index in entries.indices where entries[index].mirror == nil && (entries[index].showsInCalendar || includingDdayOnly) {
            let link = CalendarMirror(calendarID: calendarID)
            do {
                entries[index].mirror = try backend.writeMirror(MirrorEventSpec(entries[index]), link: link)
                result.written += 1
                result.entryIDs.append(entries[index].id)
            } catch let error as MirrorError where error.stopsBatch {
                result.stoppedBy = error.localizedDescription       // every other entry would fail the same way
                break
            } catch {
                entries[index].mirror = link                         // stays pending: the banner offers 다시 시도
                result.failed += 1
                result.entryIDs.append(entries[index].id)
                lastError = error.localizedDescription
            }
        }
        if let reason = result.stoppedBy {
            mirrorNotice = "일정을 계정 캘린더에 올리지 못했어요 · \(reason)"
        } else if result.failed > 0 {
            mirrorNotice = "일정 \(result.failed)개를 아직 계정 캘린더에 못 올렸어요 · \(lastError)"
        }
        lastBulkMirror = result
        if !result.entryIDs.isEmpty {
            backend.mirrorLinksChanged()
            scheduleSave()
        }
        return result
    }

    /// 되돌리기: removes the copies the last "모두 올리기" made and unlinks those entries. Returns how many were unlinked.
    @discardableResult
    func undoLastBulkMirror() -> Int {
        guard let last = lastBulkMirror else { return 0 }
        lastBulkMirror = nil
        var unlinked = 0
        var allRemoved = true
        for id in last.entryIDs {
            // Entries the user has since deleted or unlinked by hand are simply skipped.
            guard let index = entries.firstIndex(where: { $0.id == id }), let link = entries[index].mirror else { continue }
            if link.isWritten, !removeCopy(link, title: entries[index].title) { allRemoved = false }
            entries[index].mirror = nil
            unlinked += 1
        }
        if allRemoved, pendingMirrorCount == 0 { mirrorNotice = nil }
        if unlinked > 0 {
            mirrorBackend?.mirrorLinksChanged()
            scheduleSave()
        }
        return unlinked
    }

    func dismissBulkMirrorReport() { lastBulkMirror = nil }

    /// Brings the copy in line with `entry` (create / update / move / remove) and returns the entry with its refreshed link.
    private func syncMirror(_ entry: DateEntry, previous: DateEntry?) -> DateEntry {
        var result = entry
        let old = previous?.mirror
        guard let wanted = entry.mirror else {
            if let old, old.isWritten { removeCopy(old, title: entry.title) }
            return result
        }
        var link = CalendarMirror(calendarID: wanted.calendarID)
        if let old {
            if old.calendarID == wanted.calendarID {
                link = old                                    // the stored ids are the truth, not whatever the editor carried
            } else if old.isWritten {
                removeCopy(old, title: entry.title)           // moved to another calendar: the old copy goes away
            }
        }
        result.mirror = link
        guard let backend = mirrorBackend else { return result }
        // Nothing the copy shows has changed (colour, D-day flags, …): leave the event alone.
        if !link.needsWrite, let previous, MirrorEventSpec(previous) == MirrorEventSpec(entry) { return result }
        do {
            result.mirror = try backend.writeMirror(MirrorEventSpec(entry), link: link)
            // Clear the banner once no other entry is still waiting for its copy.
            if !entries.contains(where: { $0.id != entry.id && $0.mirror?.needsWrite == true }) { mirrorNotice = nil }
        } catch {
            if link.isWritten { result.mirror?.stale = true }
            let name = entry.title.isEmpty ? "일정" : "'\(entry.title)'"
            mirrorNotice = "\(name)을(를) 계정 캘린더에 올리지 못했어요 · \(error.localizedDescription)"
        }
        return result
    }

    @discardableResult
    private func removeCopy(_ link: CalendarMirror, title: String) -> Bool {
        guard let backend = mirrorBackend else { return false }
        do {
            try backend.removeMirror(link)
            return true
        } catch {
            let name = title.isEmpty ? "일정" : "'\(title)'"
            mirrorNotice = "\(name)의 계정 캘린더 사본을 지우지 못했어요. 캘린더 앱에서 직접 지워 주세요 · \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Search

    struct SearchHit: Identifiable {
        let entry: DateEntry
        let date: Date           // the occurrence to jump to
        var id: UUID { entry.id }
    }

    /// Keyword match on title / note; repeating entries report their next occurrence.
    func search(_ query: String, today: Date = Date()) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: today)
        return entries.filter { $0.title.lowercased().contains(needle) || $0.note.lowercased().contains(needle) }
            .map { SearchHit(entry: $0, date: Self.nextOccurrence(of: $0, from: start, calendar: calendar)) }
            .sorted { a, b in
                let aFuture = a.date >= start, bFuture = b.date >= start
                if aFuture != bFuture { return aFuture }
                return aFuture ? a.date < b.date : a.date > b.date
            }
    }

    func jump(to date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        selectedDay = day
        visibleMonth = day
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
            let ongoingStart = entry.isMultiDay ? entry.occurrenceStart(containing: start, calendar: calendar) : nil
            if let ongoingStart, entry.style != .elapsed {
                let dayIndex = (calendar.dateComponents([.day], from: ongoingStart, to: start).day ?? 0) + 1
                label = dayIndex == 1 ? "D-Day" : "\(dayIndex)일째"
                elapsed = dayIndex != 1
            } else if entry.style == .elapsed, sinceStart >= (entry.startsAtOne ? 1 : 0) {
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
        if entry.isMultiDay, let ongoing = entry.occurrenceStart(containing: today, calendar: calendar),
           let end = calendar.date(byAdding: .day, value: entry.spanDays - 1, to: ongoing) {
            let left = calendar.dateComponents([.day], from: today, to: end).day ?? 0
            return "\(entry.rangeText) · " + (left == 0 ? "오늘 마지막 날" : "끝까지 D-\(left)")
        }
        switch entry.repeatRule {
        case .none:
            var parts = [entry.isMultiDay ? entry.rangeText : f.string(from: entry.date) + (entry.timeText.map { " \($0)" } ?? "")]
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
