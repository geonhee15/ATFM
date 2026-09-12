import Foundation
import Observation

struct Holiday: Identifiable, Equatable {
    let id: String
    let date: Date          // start of day
    let title: String
    let region: String      // "kr", country code, or "intl"
    let flag: String
    let isPublic: Bool      // public holiday vs. observance / commemoration
}

struct HolidayCountry: Identifiable, Equatable {
    let code: String
    let name: String
    let flag: String
    let calendarID: String
    var id: String { code }

    static let all: [HolidayCountry] = [
        .init(code: "us", name: "미국", flag: "🇺🇸", calendarID: "en.usa"),
        .init(code: "jp", name: "일본", flag: "🇯🇵", calendarID: "ja.japanese"),
        .init(code: "cn", name: "중국", flag: "🇨🇳", calendarID: "zh_cn.china"),
        .init(code: "tw", name: "대만", flag: "🇹🇼", calendarID: "zh_tw.taiwan"),
        .init(code: "hk", name: "홍콩", flag: "🇭🇰", calendarID: "en.hong_kong"),
        .init(code: "gb", name: "영국", flag: "🇬🇧", calendarID: "en.uk"),
        .init(code: "de", name: "독일", flag: "🇩🇪", calendarID: "de.german"),
        .init(code: "fr", name: "프랑스", flag: "🇫🇷", calendarID: "fr.french"),
        .init(code: "ca", name: "캐나다", flag: "🇨🇦", calendarID: "en.canadian"),
        .init(code: "au", name: "호주", flag: "🇦🇺", calendarID: "en.australian"),
        .init(code: "vn", name: "베트남", flag: "🇻🇳", calendarID: "vi.vietnamese"),
        .init(code: "th", name: "태국", flag: "🇹🇭", calendarID: "th.th"),
        .init(code: "sg", name: "싱가포르", flag: "🇸🇬", calendarID: "en.singapore"),
        .init(code: "ph", name: "필리핀", flag: "🇵🇭", calendarID: "en.philippines"),
        .init(code: "id", name: "인도네시아", flag: "🇮🇩", calendarID: "id.indonesian"),
        .init(code: "in", name: "인도", flag: "🇮🇳", calendarID: "en.indian"),
    ]
}

/// Public holidays (Korea + other countries) from Google's public holiday iCal feeds, cached on disk,
/// plus a built-in list of international days. Everything is read-only decoration for the calendar.
@MainActor
@Observable
final class HolidayStore {
    var showKorean: Bool { didSet { UserDefaults.standard.set(showKorean, forKey: Self.koreanKey); ensureLoaded("kr") } }
    var showKoreanObservances: Bool { didSet { UserDefaults.standard.set(showKoreanObservances, forKey: Self.koreanObsKey) } }
    var showInternationalDays: Bool { didSet { UserDefaults.standard.set(showInternationalDays, forKey: Self.intlKey) } }
    private(set) var countries: Set<String>
    private(set) var loaded: [String: [Holiday]] = [:]      // region → holidays
    private(set) var fetching: Set<String> = []
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?

    @ObservationIgnored private let cacheDirectory: URL
    private static let koreanKey = "holidaysKorean"
    private static let koreanObsKey = "holidaysKoreanObservances"
    private static let intlKey = "holidaysInternational"
    private static let countriesKey = "holidaysCountries"
    private static let refreshKey = "holidaysLastRefresh"
    private static let maxAge: TimeInterval = 7 * 86_400

    init(directory: URL) {
        cacheDirectory = directory.appendingPathComponent("holidays", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        showKorean = UserDefaults.standard.object(forKey: Self.koreanKey) as? Bool ?? true
        showKoreanObservances = UserDefaults.standard.bool(forKey: Self.koreanObsKey)
        showInternationalDays = UserDefaults.standard.bool(forKey: Self.intlKey)
        countries = Set(UserDefaults.standard.stringArray(forKey: Self.countriesKey) ?? [])
        lastRefresh = UserDefaults.standard.object(forKey: Self.refreshKey) as? Date
        loaded["intl"] = Self.internationalDays(years: Self.yearsAround())
        if showKorean { ensureLoaded("kr") }
        for code in countries { ensureLoaded(code) }
    }

    // MARK: Queries

    func holidays(on day: Date) -> [Holiday] {
        let start = Calendar.current.startOfDay(for: day)
        var result: [Holiday] = []
        if showKorean, let list = loaded["kr"] {
            result += list.filter { $0.date == start && ($0.isPublic || showKoreanObservances) }
        }
        for code in countries.sorted() {
            if let list = loaded[code] { result += list.filter { $0.date == start && $0.isPublic } }
        }
        if showInternationalDays, let list = loaded["intl"] {
            result += list.filter { $0.date == start }
        }
        return result
    }

    func isKoreanPublicHoliday(_ day: Date) -> Bool {
        guard showKorean, let list = loaded["kr"] else { return false }
        let start = Calendar.current.startOfDay(for: day)
        return list.contains { $0.date == start && $0.isPublic }
    }

    var activeCountries: [HolidayCountry] { HolidayCountry.all.filter { countries.contains($0.code) } }

    func toggleCountry(_ code: String) {
        if countries.contains(code) { countries.remove(code) } else { countries.insert(code); ensureLoaded(code) }
        UserDefaults.standard.set(Array(countries).sorted(), forKey: Self.countriesKey)
    }

    func refreshAll() {
        var regions = ["kr"]
        regions += countries.sorted()
        for region in regions { fetch(region, force: true) }
    }

    // MARK: Loading

    private func ensureLoaded(_ region: String) {
        if loaded[region] == nil, let cached = try? String(contentsOf: cacheURL(region), encoding: .utf8) {
            loaded[region] = Self.parse(ics: cached, region: region)
        }
        if region == "kr", loaded["kr"]?.isEmpty ?? true {
            loaded["kr"] = KoreanHolidayFallback.holidays(years: Self.yearsAround())   // until the feed arrives
        }
        let stale: Bool
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL(region).path),
           let modified = attrs[.modificationDate] as? Date {
            stale = Date().timeIntervalSince(modified) > Self.maxAge
        } else {
            stale = true
        }
        if stale { fetch(region, force: false) }
    }

    private func calendarID(for region: String) -> String? {
        if region == "kr" { return "ko.south_korea" }
        return HolidayCountry.all.first { $0.code == region }?.calendarID
    }

    private func cacheURL(_ region: String) -> URL {
        cacheDirectory.appendingPathComponent("\(region).ics")
    }

    private func fetch(_ region: String, force: Bool) {
        guard !fetching.contains(region), let calendarID = calendarID(for: region) else { return }
        let encoded = "\(calendarID)%23holiday%40group.v.calendar.google.com"
        guard let url = URL(string: "https://calendar.google.com/calendar/ical/\(encoded)/public/basic.ics") else { return }
        fetching.insert(region)
        let cache = cacheURL(region)
        Task { [weak self] in
            var text: String?
            var failure: String?
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200, let body = String(data: data, encoding: .utf8), body.contains("BEGIN:VCALENDAR") {
                    text = body
                    try? body.write(to: cache, atomically: true, encoding: .utf8)
                } else {
                    failure = "공휴일 데이터를 받지 못했어요 (\(region))"
                }
            } catch {
                failure = "공휴일 데이터 요청 실패: \(error.localizedDescription)"
            }
            guard let self else { return }
            self.fetching.remove(region)
            if let text {
                self.loaded[region] = Self.parse(ics: text, region: region)
                self.lastRefresh = Date()
                UserDefaults.standard.set(self.lastRefresh, forKey: Self.refreshKey)
                self.lastError = nil
            } else if let failure, self.loaded[region]?.isEmpty ?? true {
                self.lastError = failure
            }
        }
    }

    // MARK: ICS parsing (Google all-day VEVENTs)

    static func parse(ics: String, region: String) -> [Holiday] {
        // Unfold continuation lines first.
        var lines: [String] = []
        for raw in ics.components(separatedBy: .newlines) {
            if raw.hasPrefix(" ") || raw.hasPrefix("\t"), !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(raw)
            }
        }
        let flag = region == "kr" ? "🇰🇷" : (HolidayCountry.all.first { $0.code == region }?.flag ?? "🏳️")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone.current
        formatter.calendar = Calendar.current
        var holidays: [Holiday] = []
        var inEvent = false
        var start: String?, summary: String?, description: String?, uid: String?
        for line in lines {
            if line == "BEGIN:VEVENT" { inEvent = true; start = nil; summary = nil; description = nil; uid = nil; continue }
            if line == "END:VEVENT" {
                inEvent = false
                if let start, let summary, let date = formatter.date(from: String(start.prefix(8))) {
                    let day = Calendar.current.startOfDay(for: date)
                    let lower = (description ?? "").lowercased()
                    var isPublic = !(lower.hasPrefix("기념일") || lower.contains("observance") || lower.contains("行事") || lower.contains("節日") || lower.contains("silent"))
                    if region == "kr", Self.koreanNonPublic.contains(where: { summary.hasPrefix($0) }) { isPublic = false }
                    let cleanTitle = summary.replacingOccurrences(of: "\\,", with: ",")
                    holidays.append(Holiday(id: "\(region)-\(uid ?? "")-\(start)", date: day, title: cleanTitle,
                                            region: region, flag: flag, isPublic: isPublic))
                }
                continue
            }
            guard inEvent else { continue }
            if line.hasPrefix("DTSTART") { start = line.split(separator: ":", maxSplits: 1).last.map(String.init) }
            else if line.hasPrefix("SUMMARY") { summary = line.split(separator: ":", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) } }
            else if line.hasPrefix("DESCRIPTION") { description = line.split(separator: ":", maxSplits: 1).last.map(String.init) }
            else if line.hasPrefix("UID") { uid = line.split(separator: ":", maxSplits: 1).last.map(String.init) }
        }
        return holidays.sorted { $0.date < $1.date }
    }

    /// Google labels these 공휴일 but they are not days off in Korea.
    private static let koreanNonPublic = ["제헌절", "노동절", "근로자의 날"]

    // MARK: Built-in international days

    static func yearsAround(_ date: Date = Date()) -> [Int] {
        let year = Calendar.current.component(.year, from: date)
        return [year - 1, year, year + 1]
    }

    private static let internationalDayList: [(month: Int, day: Int, title: String)] = [
        (2, 14, "발렌타인데이"), (3, 8, "세계 여성의 날"), (3, 14, "화이트데이"), (3, 22, "세계 물의 날"), (4, 1, "만우절"),
        (4, 7, "세계 보건의 날"), (4, 22, "지구의 날"), (4, 23, "세계 책의 날"), (5, 1, "세계 노동절"), (6, 5, "세계 환경의 날"),
        (6, 8, "세계 해양의 날"), (7, 11, "세계 인구의 날"), (8, 12, "세계 청년의 날"), (9, 21, "세계 평화의 날"),
        (10, 4, "세계 동물의 날"), (10, 16, "세계 식량의 날"), (10, 24, "유엔의 날"), (10, 31, "핼러윈"),
        (12, 1, "세계 에이즈의 날"), (12, 10, "세계 인권의 날"), (12, 31, "새해 전야"),
    ]

    static func internationalDays(years: [Int]) -> [Holiday] {
        let calendar = Calendar.current
        var out: [Holiday] = []
        for year in years {
            for item in internationalDayList {
                if let date = calendar.date(from: DateComponents(year: year, month: item.month, day: item.day)) {
                    out.append(Holiday(id: "intl-\(year)-\(item.month)-\(item.day)", date: calendar.startOfDay(for: date),
                                       title: item.title, region: "intl", flag: "🌐", isPublic: false))
                }
            }
        }
        return out
    }
}

/// Offline stand-in for the Korean feed: fixed-date holidays plus the lunar ones (no substitute days).
enum KoreanHolidayFallback {
    private static let fixed: [(Int, Int, String)] = [
        (1, 1, "새해첫날"), (3, 1, "삼일절"), (5, 5, "어린이날"), (6, 6, "현충일"), (8, 15, "광복절"),
        (10, 3, "개천절"), (10, 9, "한글날"), (12, 25, "크리스마스"),
    ]

    static func holidays(years: [Int]) -> [Holiday] {
        let gregorian = Calendar.current
        var out: [Holiday] = []
        for year in years {
            for (month, day, title) in fixed {
                if let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)) {
                    out.append(Holiday(id: "kr-fb-\(year)-\(month)-\(day)", date: gregorian.startOfDay(for: date), title: title, region: "kr", flag: "🇰🇷", isPublic: true))
                }
            }
            for (month, day, title, spread) in [(1, 1, "설날", true), (8, 15, "추석", true), (4, 8, "부처님오신날", false)] {
                guard let center = lunarDate(year: year, month: month, day: day) else { continue }
                let offsets = spread ? [-1, 0, 1] : [0]
                for offset in offsets {
                    if let date = gregorian.date(byAdding: .day, value: offset, to: center) {
                        out.append(Holiday(id: "kr-fb-lunar-\(year)-\(month)-\(day)-\(offset)", date: gregorian.startOfDay(for: date),
                                           title: offset == 0 ? title : "\(title) 연휴", region: "kr", flag: "🇰🇷", isPublic: true))
                    }
                }
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Gregorian date of a (non-leap) lunar month/day in the given Gregorian year.
    private static func lunarDate(year: Int, month: Int, day: Int) -> Date? {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = TimeZone.current
        let gregorian = Calendar.current
        // Try every candidate lunar year that overlaps this Gregorian year.
        for probeMonth in [2, 7] {
            guard let probe = gregorian.date(from: DateComponents(year: year, month: probeMonth, day: 15)) else { continue }
            let comps = chinese.dateComponents([.era, .year], from: probe)
            var target = DateComponents()
            target.era = comps.era
            target.year = comps.year
            target.month = month
            target.day = day
            target.isLeapMonth = false
            if let date = chinese.date(from: target), gregorian.component(.year, from: date) == year {
                return date
            }
        }
        return nil
    }
}
