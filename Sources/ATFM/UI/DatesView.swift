import SwiftUI

struct DatesView: View {
    @Bindable var store: DateStore
    @Bindable var external: ExternalCalendarSource
    @Environment(\.colorScheme) private var scheme
    @State private var editing: DateEntry?
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                if ProcessInfo.processInfo.environment["ATFM_DEBUG_DATES_EDITOR"] == "1" {   // snapshot the editor inline
                    EntryEditor(entry: DateEntry(title: "제주 여행", year: 2026, month: 9, day: 21, colorIndex: 3, showsInDday: true),
                                isNew: true) { _ in }
                        .card()
                }
                ClockCard()
                calendarCard
                selectedDayCard
                ddayCard
                schoolCard
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .onAppear { external.refresh(around: store.visibleMonth) }
        .onChange(of: store.visibleMonth) { _, month in external.refresh(around: month) }
        .popover(isPresented: $showEditor, arrowEdge: .top) {
            if let editing {
                EntryEditor(entry: editing, isNew: !store.entries.contains { $0.id == editing.id }) { result in
                    switch result {
                    case .save(let entry): store.update(entry)
                    case .delete(let id): store.delete(id)
                    case .cancel: break
                    }
                    showEditor = false
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("날짜")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("오늘") { store.goToday() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Calendar

    private var calendarCard: some View {
        VStack(spacing: 6) {
            HStack {
                Button { store.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text(Self.monthTitle(store.visibleMonth))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            HStack(spacing: 0) {
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { index, name in
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(index == 0 ? Color.red.opacity(0.8) : index == 6 ? Color.blue.opacity(0.8) : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            let grid = store.monthGrid()
            let calendar = Calendar.current
            let month = calendar.component(.month, from: store.visibleMonth)
            let today = calendar.startOfDay(for: Date())
            VStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { column in
                            let day = grid[row * 7 + column]
                            DayCell(day: day,
                                    inMonth: calendar.component(.month, from: day) == month,
                                    isToday: day == today,
                                    isSelected: day == store.selectedDay,
                                    weekday: column,
                                    events: store.events(on: day),
                                    external: external.events(on: day)) {
                                store.selectedDay = day
                            } add: {
                                store.selectedDay = day
                                beginAdd(on: day, dday: false)
                            }
                            .contextMenu {
                                Button { store.selectedDay = day; beginAdd(on: day, dday: false) } label: { Label("이 날에 일정 추가", systemImage: "plus") }
                                let dayEvents = store.events(on: day)
                                if !dayEvents.isEmpty {
                                    Divider()
                                    ForEach(dayEvents) { event in
                                        Menu(event.title.isEmpty ? "(제목 없음)" : event.title) { contextMenu(for: event) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .card()
    }

    private var selectedDayCard: some View {
        let events = store.events(on: store.selectedDay)
        let schoolEvents = external.events(on: store.selectedDay)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.dayTitle(store.selectedDay))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    beginAdd(on: store.selectedDay, dday: false)
                } label: {
                    Label("일정 추가", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            if events.isEmpty && schoolEvents.isEmpty {
                Text("일정 없음 · 더블클릭 또는 우클릭으로 추가")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(events) { event in
                    EventRow(entry: event) { begin(edit: event) }
                        .contextMenu { contextMenu(for: event) }
                }
                ForEach(schoolEvents) { event in
                    ExternalEventRow(event: event)
                        .contextMenu {
                            Button { external.openInCalendarApp(event) } label: { Label("캘린더 앱에서 열기", systemImage: "calendar") }
                            Button { external.toggleCalendar(event.calendarID) } label: { Label("'\(event.calendarTitle)' 캘린더 숨기기", systemImage: "eye.slash") }
                        }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: D-days

    private var ddayCard: some View {
        let items = store.ddays()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("D-days")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    beginAdd(on: Calendar.current.startOfDay(for: Date()), dday: true)
                } label: {
                    Label("기념일 추가", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .padding(.bottom, 2)
            if items.isEmpty {
                Text("아직 없어요. 기념일을 추가하거나, 일정에서 'D-day에 표시'를 켜 보세요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(items) { info in
                    DDayRow(info: info) { begin(edit: info.entry) }
                        .contextMenu { contextMenu(for: info.entry) }
                    if info.id != items.last?.id { Divider() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: 학교 스케줄 (macOS 캘린더 앱에서 가져오기)

    private var schoolCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "graduationcap")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("학교 스케줄 보이기")
                        .font(.system(size: 14, weight: .semibold))
                    Text(schoolSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $external.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if external.isEnabled {
                if external.isDenied {
                    HStack(spacing: 8) {
                        Text("캘린더 접근이 꺼져 있어요.")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                        Button("설정 열기") { external.openPrivacySettings() }
                            .controlSize(.mini)
                    }
                    .padding(.leading, 40)
                } else if !external.hasAccess {
                    HStack(spacing: 8) {
                        Text("캘린더 접근 권한이 필요해요.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("권한 요청") { external.requestAccess() }
                            .controlSize(.mini)
                    }
                    .padding(.leading, 40)
                } else if external.calendars.isEmpty {
                    Text("캘린더 앱에 연결된 캘린더가 없어요. 시스템 설정 › 인터넷 계정에서 학교 계정을 추가하고 '캘린더'를 켜 주세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 40)
                } else {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(external.groupedCalendars, id: \.account) { group in
                                HStack {
                                    Text(group.account)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    let allOn = group.calendars.allSatisfy { external.selectedIDs.contains($0.id) }
                                    Button(allOn ? "모두 해제" : "모두 선택") { external.selectAll(in: group.account, on: !allOn) }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.accent)
                                }
                                .padding(.top, 4)
                                ForEach(group.calendars) { calendar in
                                    Toggle(isOn: Binding(get: { external.selectedIDs.contains(calendar.id) },
                                                         set: { _ in external.toggleCalendar(calendar.id) })) {
                                        HStack(spacing: 6) {
                                            Circle().fill(calendar.color).frame(width: 8, height: 8)
                                            Text(calendar.title).font(.system(size: 12)).lineLimit(1)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("가져올 캘린더 · \(external.selectedCalendars.count)개 선택")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 40)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private var schoolSubtitle: String {
        if !external.isEnabled { return "이 Mac의 캘린더 앱에 연결된 계정(학교 구글 계정 등)의 일정을 달력에 함께 보여줘요." }
        let count = external.events.count
        return count == 0 ? "이번 달 가져온 일정이 없어요. 아래에서 캘린더를 골라 보세요." : "이번 달 \(count)개 일정을 가져왔어요 (읽기 전용 · 링 모양 점)."
    }

    // MARK: Context menu (우클릭)

    @ViewBuilder
    private func contextMenu(for entry: DateEntry) -> some View {
        Button { begin(edit: entry) } label: { Label("수정…", systemImage: "pencil") }
        Divider()
        Button {
            var copy = entry; copy.showsInDday.toggle()
            if !copy.showsInDday && !copy.showsInCalendar { copy.showsInCalendar = true }
            store.update(copy)
        } label: {
            Label(entry.showsInDday ? "D-day에서 빼기" : "D-day에 표시", systemImage: "flag")
        }
        Button {
            var copy = entry; copy.showsInCalendar.toggle()
            if !copy.showsInCalendar && !copy.showsInDday { copy.showsInDday = true }
            store.update(copy)
        } label: {
            Label(entry.showsInCalendar ? "캘린더에서 빼기" : "캘린더에 표시", systemImage: "calendar")
        }
        if entry.showsInDday {
            Button {
                var copy = entry; copy.ddayStyle = entry.style == .elapsed ? .countdown : .elapsed
                store.update(copy)
            } label: {
                Label(entry.style == .elapsed ? "크게 표시: 기념일까지 D-" : "크게 표시: 처음부터 D+", systemImage: "arrow.left.arrow.right")
            }
        }
        Menu("반복") {
            ForEach(DateEntry.Repeat.allCases) { rule in
                Button {
                    var copy = entry; copy.repeatRule = rule; store.update(copy)
                } label: {
                    if entry.repeatRule == rule { Label(rule.title, systemImage: "checkmark") } else { Text(rule.title) }
                }
            }
        }
        Menu("색") {
            ForEach(Array(DateEntry.palette.enumerated()), id: \.offset) { index, _ in
                Button {
                    var copy = entry; copy.colorIndex = index; store.update(copy)
                } label: {
                    let name = ["파랑", "빨강", "주황", "초록", "보라", "분홍", "회색"][index]
                    if entry.colorIndex == index { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        }
        Button {
            var copy = entry; copy.id = UUID(); copy.title += " 사본"; copy.createdAt = Date()
            store.add(copy)
        } label: { Label("복제", systemImage: "plus.square.on.square") }
        Divider()
        Button(role: .destructive) { store.delete(entry.id) } label: { Label("삭제", systemImage: "trash") }
    }

    // MARK: Editing

    private func beginAdd(on day: Date, dday: Bool) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        editing = DateEntry(title: "", year: c.year ?? 2026, month: c.month ?? 1, day: c.day ?? 1,
                            colorIndex: dday ? 1 : 0, showsInCalendar: !dday, showsInDday: dday,
                            repeatRule: dday ? .yearly : .none)
        showEditor = true
    }

    private func begin(edit entry: DateEntry) {
        editing = entry
        showEditor = true
    }

    static func monthTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "yyyy년 M월"
        return f.string(from: date)
    }

    static func dayTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M월 d일 (E)"
        let calendar = Calendar.current
        let text = f.string(from: date)
        return calendar.isDateInToday(date) ? text + " · 오늘" : text
    }
}

// MARK: - Clock

private struct ClockCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dateText(now))
                        .font(.system(size: 15, weight: .semibold))
                    Text(Self.subText(now))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.timeText(now))
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .card()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "yyyy년 M월 d일 EEEE"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm:ss"; return f
    }()

    static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func timeText(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func subText(_ date: Date) -> String {
        let calendar = Calendar.current
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        let week = calendar.component(.weekOfYear, from: date)
        let daysInYear = calendar.range(of: .day, in: .year, for: date)?.count ?? 365
        return "올해 \(dayOfYear)일째 · \(week)주차 · \(daysInYear - dayOfYear)일 남음"
    }
}

// MARK: - Calendar cell

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let weekday: Int
    let events: [DateEntry]
    var external: [ExternalEvent] = []
    let select: () -> Void
    let add: () -> Void

    private var number: String { "\(Calendar.current.component(.day, from: day))" }

    private var numberColor: Color {
        if isToday { return .white }
        if !inMonth { return Color.secondary.opacity(0.4) }
        if weekday == 0 { return Color.red.opacity(0.85) }
        if weekday == 6 { return Color.blue.opacity(0.85) }
        return .primary
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(number)
                .font(.system(size: 11, weight: isToday ? .bold : .medium))
                .foregroundStyle(numberColor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(isToday ? Theme.accent : Color.clear))
            let singles = events.filter { !$0.isMultiDay }
            let spans = events.filter(\.isMultiDay)
            HStack(spacing: 2) {
                ForEach(singles.prefix(3)) { event in
                    Circle().fill(event.color).frame(width: 4, height: 4)
                }
                ForEach(external.prefix(max(0, 4 - min(singles.count, 3)))) { event in
                    Circle().strokeBorder(event.color, lineWidth: 1.2).frame(width: 5, height: 5)
                }
                if singles.count > 3 || external.count > 4 - min(singles.count, 3) {
                    Text("+").font(.system(size: 7)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 5)
            VStack(spacing: 1) {
                ForEach(spans.prefix(2)) { event in
                    SpanBar(color: event.color, isStart: event.isSpanStart(day), isEnd: event.isSpanEnd(day))
                }
            }
            .frame(height: spans.isEmpty ? 0 : 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: add)
        .onTapGesture(perform: select)
        .opacity(inMonth ? 1 : 0.7)
    }
}

/// A slice of a multi-day event: rounded on the first/last day so the run reads as one bar.
private struct SpanBar: View {
    let color: Color
    let isStart: Bool
    let isEnd: Bool

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: isStart ? 2 : 0, bottomLeadingRadius: isStart ? 2 : 0,
                               bottomTrailingRadius: isEnd ? 2 : 0, topTrailingRadius: isEnd ? 2 : 0)
            .fill(color.opacity(0.85))
            .frame(height: 2)
            .padding(.leading, isStart ? 3 : -1)
            .padding(.trailing, isEnd ? 3 : -1)
    }
}

private struct EventRow: View {
    let entry: DateEntry
    let edit: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(entry.color).frame(width: 4, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? "(제목 없음)" : entry.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if entry.isMultiDay {
                    Text(entry.rangeText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else if !entry.note.isEmpty {
                    Text(entry.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if entry.repeatRule != .none {
                Text(entry.repeatRule.title).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if entry.showsInDday {
                Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(entry.color)
            }
            Text(entry.timeText ?? "종일")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hoverFill(scheme) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .onHover { hovering = $0 }
        .help("클릭: 편집 · 우클릭: 더 많은 옵션")
    }
}

private struct ExternalEventRow: View {
    let event: ExternalEvent
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).strokeBorder(event.color, lineWidth: 1.5).frame(width: 4, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(event.location.map { "\(event.calendarTitle) · \($0)" } ?? event.calendarTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "graduationcap.fill").font(.system(size: 9)).foregroundStyle(event.color)
            Text(event.timeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hoverFill(scheme) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("캘린더 앱에서 가져온 일정 · 우클릭으로 열기")
    }
}

private struct DDayRow: View {
    let info: DDayInfo
    let edit: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    /// 처음부터 D+ → blue, 기념일까지 D- / D-Day → red (the user's convention).
    private var labelColor: Color {
        info.isElapsed ? Color(red: 0.25, green: 0.50, blue: 0.95) : Color(red: 0.92, green: 0.27, blue: 0.30)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(info.label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(labelColor)
                .frame(minWidth: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.entry.title.isEmpty ? "(제목 없음)" : info.entry.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(info.secondary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if info.entry.showsInCalendar {
                Image(systemName: "calendar").font(.system(size: 10)).foregroundStyle(.tertiary).help("캘린더에도 표시")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hoverFill(scheme) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .onHover { hovering = $0 }
        .help("클릭: 편집 · 우클릭: 더 많은 옵션")
    }
}

// MARK: - Editor

private struct EntryEditor: View {
    enum Result { case save(DateEntry), delete(UUID), cancel }

    @State var entry: DateEntry
    let isNew: Bool
    let finish: (Result) -> Void

    @State private var date: Date
    @State private var time: Date
    @State private var endDate: Date
    @State private var hasEnd: Bool
    @FocusState private var titleFocused: Bool

    init(entry: DateEntry, isNew: Bool, finish: @escaping (Result) -> Void) {
        _entry = State(initialValue: entry)
        self.isNew = isNew
        self.finish = finish
        _date = State(initialValue: entry.date)
        _endDate = State(initialValue: entry.isMultiDay ? entry.endDate : (Calendar.current.date(byAdding: .day, value: 1, to: entry.date) ?? entry.date))
        _hasEnd = State(initialValue: entry.isMultiDay)
        var t = DateComponents(); t.hour = entry.hour ?? 9; t.minute = entry.minute ?? 0
        _time = State(initialValue: Calendar.current.date(from: t) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? (entry.showsInDday && !entry.showsInCalendar ? "기념일 추가" : "일정 추가") : "편집")
                .font(.system(size: 13, weight: .semibold))
            TextField("제목", text: $entry.title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
            DatePicker(hasEnd ? "시작" : "날짜", selection: $date, displayedComponents: .date)
                .datePickerStyle(.compact)
            Toggle("기간 (며칠부터 며칠까지)", isOn: $hasEnd)
            if hasEnd {
                DatePicker("종료", selection: $endDate, in: date..., displayedComponents: .date)
                    .datePickerStyle(.compact)
                Text("\(spanDaysPreview)일간")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Toggle("시간", isOn: Binding(get: { entry.hasTime }, set: { on in
                if on { entry.hour = Calendar.current.component(.hour, from: time); entry.minute = Calendar.current.component(.minute, from: time) }
                else { entry.hour = nil; entry.minute = nil }
            }))
            if entry.hasTime {
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
            TextField("메모 (선택)", text: $entry.note)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text("색").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(Array(DateEntry.palette.enumerated()), id: \.offset) { index, color in
                    Circle().fill(color).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(entry.colorIndex == index ? 0.7 : 0), lineWidth: 2))
                        .onTapGesture { entry.colorIndex = index }
                }
            }
            Divider()
            Toggle("캘린더에 표시", isOn: $entry.showsInCalendar)
            Toggle("D-day에 표시", isOn: $entry.showsInDday)
            Picker("반복", selection: $entry.repeatRule) {
                ForEach(DateEntry.Repeat.allCases) { rule in Text(rule.title).tag(rule) }
            }
            .pickerStyle(.segmented)
            Text(repeatHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if entry.showsInDday {
                Picker("크게 표시", selection: Binding(get: { entry.style }, set: { entry.ddayStyle = $0 })) {
                    ForEach(DateEntry.DDayStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.92, green: 0.27, blue: 0.30)).frame(width: 8, height: 8)
                    Text("기념일까지는 빨강").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Circle().fill(Color(red: 0.25, green: 0.50, blue: 0.95)).frame(width: 8, height: 8)
                    Text("처음부터는 파랑").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if entry.style == .elapsed {
                    Toggle("시작일을 1일로 세기 (D+1부터)", isOn: Binding(get: { entry.startsAtOne }, set: { entry.countsStartAsOne = $0 }))
                }
            }
            HStack {
                if !isNew {
                    Button("삭제", role: .destructive) { finish(.delete(entry.id)) }
                }
                Spacer()
                Button("취소") { finish(.cancel) }
                Button("저장") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!entry.showsInCalendar && !entry.showsInDday)
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 280)
        .onAppear { titleFocused = true }
    }

    private var spanDaysPreview: Int {
        let a = Calendar.current.startOfDay(for: date), b = Calendar.current.startOfDay(for: endDate)
        return max(1, (Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0) + 1)
    }

    private var repeatHint: String {
        switch entry.repeatRule {
        case .none: return "지나면 D+N 으로 세어요."
        case .monthly: return "매월 같은 날짜까지 D-N 으로 세어요."
        case .yearly: return "매년 같은 날짜까지 D-N, 그리고 N주년 · 처음부터 D+N 도 보여줘요."
        }
    }

    private func save() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        entry.year = c.year ?? entry.year
        entry.month = c.month ?? entry.month
        entry.day = c.day ?? entry.day
        if entry.hasTime {
            entry.hour = Calendar.current.component(.hour, from: time)
            entry.minute = Calendar.current.component(.minute, from: time)
        }
        entry.setEnd(hasEnd ? endDate : nil)
        if entry.title.trimmingCharacters(in: .whitespaces).isEmpty { entry.title = entry.showsInDday ? "기념일" : "일정" }
        finish(.save(entry))
    }
}
