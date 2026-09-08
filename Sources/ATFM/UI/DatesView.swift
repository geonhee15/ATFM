import SwiftUI

struct DatesView: View {
    @Bindable var store: DateStore
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
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
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
                                    events: store.events(on: day)) {
                                store.selectedDay = day
                            } add: {
                                store.selectedDay = day
                                beginAdd(on: day, dday: false)
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
            if events.isEmpty {
                Text("일정 없음 · 날짜를 더블클릭하거나 + 로 추가")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(events) { event in
                    EventRow(entry: event) { begin(edit: event) }
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
                    if info.id != items.last?.id { Divider() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
            HStack(spacing: 2) {
                ForEach(events.prefix(3)) { event in
                    Circle().fill(event.color).frame(width: 4, height: 4)
                }
                if events.count > 3 {
                    Text("+").font(.system(size: 7)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
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
                if !entry.note.isEmpty {
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
        .help("클릭해서 편집")
    }
}

private struct DDayRow: View {
    let info: DDayInfo
    let edit: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var labelColor: Color {
        if info.isToday { return .red }
        if info.isPast { return .secondary }
        return info.entry.color
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
        .help("클릭해서 편집")
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
    @FocusState private var titleFocused: Bool

    init(entry: DateEntry, isNew: Bool, finish: @escaping (Result) -> Void) {
        _entry = State(initialValue: entry)
        self.isNew = isNew
        self.finish = finish
        _date = State(initialValue: entry.date)
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
            DatePicker("날짜", selection: $date, displayedComponents: .date)
                .datePickerStyle(.compact)
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
        if entry.title.trimmingCharacters(in: .whitespaces).isEmpty { entry.title = entry.showsInDday ? "기념일" : "일정" }
        finish(.save(entry))
    }
}
