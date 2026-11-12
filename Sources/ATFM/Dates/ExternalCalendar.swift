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
    /// Events can be added to it (not a subscribed / birthdays / read-only calendar).
    var isWritable = false
    /// Belongs to an account that looks like Google (preselected for "구글 캘린더에도 추가").
    var looksGoogle = false
}

/// The 날짜 tab's bridge to the Calendar.app database (EventKit).
/// - Shows calendars the user picked (typically the school Google account that can't be reached through
///   Google's API) as a read-only overlay.
/// - Writes copies of ATFM entries that ask for one ("구글 캘린더에도 추가") into an account calendar; the
///   Calendar app's own sync then carries them to Google. Only those copies are ever written or removed.
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

    /// New calendar entries start with "구글 캘린더에도 추가" on (remembers the last choice).
    var mirrorByDefault: Bool {
        didSet { if sample == nil { UserDefaults.standard.set(mirrorByDefault, forKey: Self.mirrorDefaultKey) } }
    }
    /// The calendar copies went into last time.
    var mirrorCalendarID: String? {
        didSet { if sample == nil { UserDefaults.standard.set(mirrorCalendarID, forKey: Self.mirrorCalendarKey) } }
    }
    /// Identifiers of the copies ATFM wrote; those events are left out of the overlay (they already show as ATFM entries).
    @ObservationIgnored var mirroredEventIDs: () -> Set<String> = { [] }
    /// Debug stand-in (ATFM_DEBUG_MIRROR_SAMPLE): fake calendars, nothing reaches EventKit.
    private(set) var sample: SampleMirrorBackend?

    private static let enabledKey = "externalCalendarEnabled"
    private static let selectedKey = "externalCalendarIDs"
    private static let mirrorDefaultKey = "datesMirrorByDefault"
    private static let mirrorCalendarKey = "datesMirrorCalendarID"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        selectedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.selectedKey) ?? [])
        mirrorByDefault = UserDefaults.standard.bool(forKey: Self.mirrorDefaultKey)
        mirrorCalendarID = UserDefaults.standard.string(forKey: Self.mirrorCalendarKey)
        authorization = EKEventStore.authorizationStatus(for: .event)
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        if hasAccess, isEnabled || mirrorByDefault { loadCalendars() }
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
            let account = calendar.source?.title ?? "기타"
            let hint = (account + " " + calendar.title).lowercased()
            return ExternalCalendarInfo(id: calendar.calendarIdentifier, title: calendar.title,
                                        account: account,
                                        color: calendar.cgColor.map { Color(cgColor: $0) } ?? .gray,
                                        isWritable: calendar.allowsContentModifications && !calendar.isImmutable,
                                        looksGoogle: hint.contains("google") || hint.contains("gmail"))
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
        let mirrored = mirroredEventIDs()
        var seen = Set<String>()
        events = found.compactMap { event -> ExternalEvent? in
            // Copies ATFM wrote itself are already on the calendar as ATFM entries.
            if !mirrored.isEmpty,
               mirrored.contains(event.eventIdentifier ?? "") || mirrored.contains(event.calendarItemExternalIdentifier ?? "") { return nil }
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

    // MARK: Copies of ATFM entries ("구글 캘린더에도 추가")

    enum MirrorState { case ready, needsPermission, denied, noCalendars }

    var mirrorState: MirrorState {
        if sample != nil { return .ready }
        if isDenied { return .denied }
        if !hasAccess { return .needsPermission }
        return writableCalendars.isEmpty ? .noCalendars : .ready
    }

    /// Calendars a copy can go into.
    var writableCalendars: [ExternalCalendarInfo] { sample?.calendars ?? calendars.filter(\.isWritable) }

    var groupedWritableCalendars: [(account: String, calendars: [ExternalCalendarInfo])] {
        let groups = Dictionary(grouping: writableCalendars, by: \.account)
        // Google accounts first, then the rest by name.
        return groups.keys.sorted { a, b in
            let ga = groups[a]!.contains(where: \.looksGoogle), gb = groups[b]!.contains(where: \.looksGoogle)
            return ga != gb ? ga : a < b
        }
        .map { (account: $0, calendars: groups[$0]!.sorted { $0.title < $1.title }) }
    }

    /// The calendar used last time if it is still there, else a Google account's main calendar (the one named after the address).
    var defaultMirrorCalendarID: String? {
        let list = writableCalendars
        if let saved = mirrorCalendarID, list.contains(where: { $0.id == saved }) { return saved }
        let google = list.filter(\.looksGoogle)
        return (google.first { $0.title.contains("@") } ?? google.first)?.id
    }

    func calendarInfo(_ id: String) -> ExternalCalendarInfo? { writableCalendars.first { $0.id == id } }

    /// Called when the user turns the option on: loads the calendar list, asking for calendar access the first time.
    func prepareMirroring() {
        guard sample == nil else { return }
        authorization = EKEventStore.authorizationStatus(for: .event)
        if hasAccess {
            loadCalendars()
        } else if authorization == .notDetermined {
            requestAccess()
        }
    }

    /// Refreshes the calendar list when access is already there. Never prompts.
    func loadCalendarsIfPossible() {
        guard sample == nil else { return }
        authorization = EKEventStore.authorizationStatus(for: .event)
        if hasAccess { loadCalendars() }
    }

    func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screenshots / probes: fake calendars and an in-memory backend. Nothing is saved to defaults or EventKit.
    func enableMirrorSample() {
        sample = SampleMirrorBackend()
        mirrorByDefault = false
        mirrorCalendarID = nil
    }

    private func existingEvent(for link: CalendarMirror) -> EKEvent? {
        if let id = link.eventID, let event = store.event(withIdentifier: id) { return event }
        guard let external = link.externalID else { return nil }
        let matches = store.calendarItems(withExternalIdentifier: external).compactMap { $0 as? EKEvent }
        return matches.first { $0.calendar?.calendarIdentifier == link.calendarID } ?? matches.first
    }
}

extension ExternalCalendarSource: CalendarMirrorBackend {
    func writeMirror(_ spec: MirrorEventSpec, link: CalendarMirror) throws -> CalendarMirror {
        if sample == nil {
            authorization = EKEventStore.authorizationStatus(for: .event)
            guard hasAccess else { throw MirrorError.noAccess }
        }
        var link = link
        if link.calendarID.isEmpty {
            // Saved before a calendar could be picked (no access yet): use the default one now.
            guard let fallback = defaultMirrorCalendarID else { throw MirrorError.calendarUnavailable }
            link.calendarID = fallback
        }
        if let sample { return try sample.writeMirror(spec, link: link) }
        guard let calendar = store.calendar(withIdentifier: link.calendarID),
              calendar.allowsContentModifications else { throw MirrorError.calendarUnavailable }
        let event = existingEvent(for: link) ?? EKEvent(eventStore: store)
        if event.calendar?.calendarIdentifier != calendar.calendarIdentifier { event.calendar = calendar }
        event.title = spec.title
        event.notes = spec.notes
        event.isAllDay = spec.isAllDay
        event.startDate = spec.start
        event.endDate = spec.end
        for rule in event.recurrenceRules ?? [] { event.removeRecurrenceRule(rule) }
        switch spec.recurrence {
        case .none: break
        case .monthly: event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil))
        case .yearly: event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil))
        }
        do {
            try store.save(event, span: .futureEvents, commit: true)
        } catch {
            throw MirrorError.failed(error.localizedDescription)
        }
        var result = link
        result.eventID = event.eventIdentifier
        result.externalID = event.calendarItemExternalIdentifier
        result.stale = nil
        return result
    }

    func removeMirror(_ link: CalendarMirror) throws {
        if let sample { return try sample.removeMirror(link) }
        authorization = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { throw MirrorError.noAccess }
        guard let event = existingEvent(for: link) else { return }   // already gone on the other side
        do {
            try store.remove(event, span: .futureEvents, commit: true)
        } catch {
            throw MirrorError.failed(error.localizedDescription)
        }
    }

    /// Re-filter the overlay now that ATFM's own list of copies is up to date (the store-changed
    /// notification can arrive before the new link has been stored).
    func mirrorLinksChanged() {
        guard sample == nil else { return }
        reload()
    }
}
