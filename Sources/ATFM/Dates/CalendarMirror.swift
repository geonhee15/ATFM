import Foundation
import SwiftUI

/// Link from an ATFM entry to its copy in a Calendar.app account calendar (Google, iCloud, …).
/// The ids stay nil until the copy has actually been written.
struct CalendarMirror: Codable, Equatable {
    var calendarID: String
    /// EKEvent.eventIdentifier — fast lookup, but it can change after a sync with the server.
    var eventID: String? = nil
    /// calendarItemExternalIdentifier — the server-side UID, used when `eventID` no longer resolves.
    var externalID: String? = nil
    /// The last write failed, so the copy is behind the ATFM entry.
    var stale: Bool? = nil

    var isWritten: Bool { eventID != nil || externalID != nil }
    var needsWrite: Bool { !isWritten || stale == true }
}

/// What the copy should look like. Plain data, so the mapping can be checked without touching EventKit.
struct MirrorEventSpec: Equatable {
    enum Recurrence: String, Equatable { case none, monthly, yearly }

    var title: String
    var notes: String?
    var isAllDay: Bool
    var start: Date
    /// All-day: the last day itself (inclusive). Timed: the end instant.
    var end: Date
    var recurrence: Recurrence

    init(_ entry: DateEntry, calendar: Calendar = .current) {
        title = entry.title
        notes = entry.note.isEmpty ? nil : entry.note
        let firstDay = entry.date
        let lastDay = entry.endDate
        if let hour = entry.hour, let minute = entry.minute {
            isAllDay = false
            start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: firstDay) ?? firstDay
            if let endHour = entry.endHour, let endMinute = entry.endMinute,
               var finish = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: lastDay) {
                // The end time sits on the last day; "23:00–01:00" on a single day runs into the next morning.
                if finish <= start { finish = calendar.date(byAdding: .day, value: 1, to: finish) ?? start.addingTimeInterval(3600) }
                end = finish
            } else if entry.isMultiDay {
                // Start time only: a span runs to the end of its last day, a single day gets one hour.
                end = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: lastDay) ?? start.addingTimeInterval(3600)
            } else {
                end = start.addingTimeInterval(3600)
            }
        } else {
            isAllDay = true
            start = firstDay
            end = lastDay
        }
        switch entry.repeatRule {
        case .none: recurrence = .none
        case .monthly: recurrence = .monthly
        case .yearly: recurrence = .yearly
        }
    }
}

enum MirrorError: LocalizedError {
    case noAccess
    case calendarUnavailable
    case failed(String)

    /// Every other write would fail the same way, so a batch ("모두 올리기") stops instead of going on.
    var stopsBatch: Bool {
        switch self {
        case .noAccess, .calendarUnavailable: return true
        case .failed: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .noAccess: return "캘린더 접근 권한이 없어요"
        case .calendarUnavailable: return "고른 캘린더를 찾을 수 없거나 쓸 수 없어요"
        case .failed(let reason): return reason
        }
    }
}

/// Where the copies get written. The real one is `ExternalCalendarSource` (EventKit).
@MainActor
protocol CalendarMirrorBackend: AnyObject {
    /// Creates the copy, or updates the one `link` points at, and returns the refreshed link.
    func writeMirror(_ spec: MirrorEventSpec, link: CalendarMirror) throws -> CalendarMirror
    /// Deletes the copy. A copy that is already gone is not an error.
    func removeMirror(_ link: CalendarMirror) throws
    /// The set of links stored in ATFM just changed (after a write, removal or delete).
    func mirrorLinksChanged()
}

/// In-memory stand-in for screenshots and `ATFM --probe` (ATFM_DEBUG_MIRROR_SAMPLE / ATFM_PROBE_MIRROR):
/// never touches EventKit, so it needs no calendar permission and writes nothing real.
@MainActor
final class SampleMirrorBackend: CalendarMirrorBackend {
    let calendars: [ExternalCalendarInfo] = [
        ExternalCalendarInfo(id: "sample-google-personal", title: "sample@gmail.com", account: "Google",
                             color: Color(red: 0.26, green: 0.52, blue: 0.96), isWritable: true, looksGoogle: true),
        ExternalCalendarInfo(id: "sample-google-family", title: "가족", account: "Google",
                             color: Color(red: 0.20, green: 0.66, blue: 0.33), isWritable: true, looksGoogle: true),
        ExternalCalendarInfo(id: "sample-icloud-home", title: "집", account: "iCloud",
                             color: Color(red: 0.95, green: 0.55, blue: 0.20), isWritable: true, looksGoogle: false),
    ]
    private(set) var events: [String: (calendarID: String, spec: MirrorEventSpec)] = [:]
    private(set) var log: [String] = []
    var failNextWrites = 0
    private var counter = 0

    func writeMirror(_ spec: MirrorEventSpec, link: CalendarMirror) throws -> CalendarMirror {
        if failNextWrites > 0 {
            failNextWrites -= 1
            log.append("FAIL   \(spec.title)")
            throw MirrorError.failed("네트워크 오류(샘플)")
        }
        var result = link
        result.stale = nil
        if let id = link.eventID, events[id] != nil {
            events[id] = (link.calendarID, spec)
            log.append("update \(id) [\(link.calendarID)] \(spec.title)")
        } else {
            counter += 1
            let id = "sample-event-\(counter)"
            events[id] = (link.calendarID, spec)
            result.eventID = id
            result.externalID = "uid-\(counter)"
            log.append("create \(id) [\(link.calendarID)] \(spec.title)")
        }
        return result
    }

    func removeMirror(_ link: CalendarMirror) throws {
        guard let id = link.eventID, events.removeValue(forKey: id) != nil else { return }
        log.append("remove \(id) [\(link.calendarID)]")
    }

    func mirrorLinksChanged() {}
}
