import AppKit
import EventKit
import Observation
import SwiftUI

/// A read-only event pulled from the macOS Calendar database (school Google account, iCloud, …).
struct ExternalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let calendarID: String
    let color: Color
    let location: String?

    /// Does the event touch `day` (a start-of-day date)?
    func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        // All-day events end at the next midnight; pull that back so they don't spill over.
        let effectiveEnd = isAllDay ? end.addingTimeInterval(-1) : end
        return start < dayEnd && effectiveEnd >= day
    }

    var isMultiDay: Bool {
        let calendar = Calendar.current
        let effectiveEnd = isAllDay ? end.addingTimeInterval(-1) : end
        return !calendar.isDate(start, inSameDayAs: effectiveEnd)
    }

    var timeText: String {
        if isAllDay { return "종일" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "HH:mm"
        return isMultiDay ? "\(f.string(from: start))~" : "\(f.string(from: start))–\(f.string(from: end))"
    }
}

struct ExternalCalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String
    let color: Color
}

/// Mirrors calendars the user picked from Calendar.app (typically the school Google account that
/// can't be reached through Google's API) into the 날짜 tab. Read-only; edits happen in Calendar.app.
@MainActor
@Observable
final class ExternalCalendarSource {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { ensureAccessAndLoad() } else { events = [] }
        }
    }
    private(set) var authorization: EKAuthorizationStatus
    private(set) var calendars: [ExternalCalendarInfo] = []
    private(set) var selectedIDs: Set<String>
    private(set) var events: [ExternalEvent] = []
    private(set) var lastError: String?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var rangeStart: Date?
    @ObservationIgnored private var rangeEnd: Date?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let enabledKey = "externalCalendarEnabled"
    private static let selectedKey = "externalCalendarIDs"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        selectedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.selectedKey) ?? [])
        authorization = EKEventStore.authorizationStatus(for: .event)
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        if isEnabled, hasAccess { loadCalendars() }
    }

    var hasAccess: Bool {
        if #available(macOS 14.0, *) { return authorization == .fullAccess }
        return authorization == .authorized
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    var selectedCalendars: [ExternalCalendarInfo] { calendars.filter { selectedIDs.contains($0.id) } }

    var groupedCalendars: [(account: String, calendars: [ExternalCalendarInfo])] {
        let groups = Dictionary(grouping: calendars, by: \.account)
        return groups.keys.sorted().map { (account: $0, calendars: groups[$0]!.sorted { $0.title < $1.title }) }
    }

    // MARK: Access

    func ensureAccessAndLoad() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        if hasAccess {
            loadCalendars()
            reload()
        } else if authorization == .notDetermined {
            requestAccess()
        }
    }

    func requestAccess() {
        let finish: (Bool, Error?) -> Void = { [weak self] granted, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.authorization = EKEventStore.authorizationStatus(for: .event)
                    self.lastError = granted ? nil : (error?.localizedDescription ?? "캘린더 접근이 허용되지 않았어요")
                    if granted {
                        self.loadCalendars()
                        self.reload()
                    }
                }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: finish)
        } else {
            store.requestAccess(to: .event, completion: finish)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Calendars

    func loadCalendars() {
        guard hasAccess else { return }
        let list = store.calendars(for: .event).map { calendar in
            ExternalCalendarInfo(id: calendar.calendarIdentifier, title: calendar.title,
                                 account: calendar.source?.title ?? "기타",
                                 color: calendar.cgColor.map { Color(cgColor: $0) } ?? .gray)
        }
        calendars = list
        // First time: preselect account calendars (Google / Exchange / other servers) — usually the school one.
        if selectedIDs.isEmpty {
            let serverIDs = store.calendars(for: .event)
                .filter { $0.source?.sourceType == .calDAV || $0.source?.sourceType == .exchange }
                .map(\.calendarIdentifier)
            selectedIDs = Set(serverIDs)
            saveSelection()
        }
    }

    func toggleCalendar(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        saveSelection()
        reload()
    }

    func selectAll(in account: String, on: Bool) {
        for calendar in calendars where calendar.account == account {
            if on { selectedIDs.insert(calendar.id) } else { selectedIDs.remove(calendar.id) }
        }
        saveSelection()
        reload()
    }

    private func saveSelection() {
        UserDefaults.standard.set(Array(selectedIDs).sorted(), forKey: Self.selectedKey)
    }

    // MARK: Events

    /// Loads events for the six-week grid around `month` (plus a little slack on both sides).
    func refresh(around month: Date) {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: month)
        guard let first = calendar.date(from: comps),
              let start = calendar.date(byAdding: .day, value: -7, to: first),
              let end = calendar.date(byAdding: .day, value: 49, to: first) else { return }
        rangeStart = start
        rangeEnd = end
        reload()
    }

    func reload() {
        guard isEnabled, hasAccess, let rangeStart, let rangeEnd else { events = []; return }
        let chosen = store.calendars(for: .event).filter { selectedIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { events = []; return }
        let predicate = store.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: chosen)
        let found = store.events(matching: predicate)
        var seen = Set<String>()
        events = found.compactMap { event -> ExternalEvent? in
            let id = (event.eventIdentifier ?? UUID().uuidString) + "@" + String(Int(event.startDate.timeIntervalSince1970))
            guard seen.insert(id).inserted else { return nil }
            return ExternalEvent(id: id, title: event.title ?? "(제목 없음)", start: event.startDate, end: event.endDate,
                                 isAllDay: event.isAllDay, calendarTitle: event.calendar.title,
                                 calendarID: event.calendar.calendarIdentifier,
                                 color: event.calendar.cgColor.map { Color(cgColor: $0) } ?? .gray,
                                 location: event.location?.isEmpty == false ? event.location : nil)
        }
        .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    func events(on day: Date) -> [ExternalEvent] {
        guard isEnabled else { return [] }
        let start = Calendar.current.startOfDay(for: day)
        return events.filter { $0.covers(start) }
    }

    func openInCalendarApp(_ event: ExternalEvent) {
        let identifier = event.id.split(separator: "@").first.map(String.init) ?? ""
        if let url = URL(string: "ical://ekevent/\(identifier)"), !identifier.isEmpty {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }
}
