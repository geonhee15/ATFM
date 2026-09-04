import SwiftUI

struct ChecklistView: View {
    @Bindable var store: ChecklistStore
    @State private var newText = ""
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var showDone = true
    @State private var confirmRemoveAll = false
    @State private var showArchive = ProcessInfo.processInfo.environment["ATFM_DEBUG_ARCHIVE"] == "1"
    @State private var confirmClearArchive = false
    @State private var collapsedDays: Set<String> = []
    @FocusState private var inputFocused: Bool
    @FocusState private var editFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            header
            if showArchive {
                if confirmClearArchive { clearArchiveBar }
                archiveArea
            } else {
                inputBar
                if confirmRemoveAll { removeAllBar }
                listArea
            }
        }
        .padding(.horizontal, 20)
        .onAppear { store.archiveYesterdayIfNeeded() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $showArchive) {
                Text("오늘").tag(false)
                Text("보관함").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 118)
            if !showArchive, !store.currentItems.isEmpty {
                Text("\(store.doneItems.count)/\(store.currentItems.count) 완료")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.chipFill(scheme)))
            }
            if showArchive, store.archivedCount > 0 {
                Text("\(store.archivedCount)개 · \(store.archiveDays.count)일")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.chipFill(scheme)))
            }
            Spacer()
            Menu {
                if showArchive {
                    Button(role: .destructive) { confirmClearArchive = true } label: {
                        Label("보관함 비우기…", systemImage: "trash")
                    }
                    .disabled(store.archivedCount == 0)
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { store.archiveAllDone() }
                    } label: { Label("완료 항목 보관", systemImage: "archivebox") }
                    .disabled(store.doneItems.isEmpty)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { store.clearDone() }
                    } label: { Label("완료 항목 지우기", systemImage: "checkmark.circle") }
                    .disabled(store.doneItems.isEmpty)
                    Divider()
                    Toggle("미완료는 다음 날로 넘기기", isOn: Binding(get: { store.carryOverUnfinished }, set: { store.carryOverUnfinished = $0 }))
                    Divider()
                    Button(role: .destructive) { confirmRemoveAll = true } label: {
                        Label("전체 삭제…", systemImage: "trash")
                    }
                    .disabled(store.currentItems.isEmpty)
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 2)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(newText.isEmpty ? Color.secondary : Color.accentColor)
            TextField("할 일을 적고 Enter", text: $newText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit(addItem)
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .card(radius: 10)
    }

    private func addItem() {
        let text = newText
        newText = ""
        withAnimation(.snappy(duration: 0.2)) { store.add(text) }
        inputFocused = true
    }

    private var clearArchiveBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("보관된 \(store.archivedCount)개를 모두 삭제할까요?")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("취소") { confirmClearArchive = false }
            Button(role: .destructive) {
                confirmClearArchive = false
                withAnimation(.snappy(duration: 0.2)) { store.removeAllArchived() }
            } label: { Text("삭제") }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .card()
    }

    private var removeAllBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("오늘 목록 \(store.currentItems.count)개를 모두 삭제할까요?")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("취소") { confirmRemoveAll = false }
            Button(role: .destructive) {
                confirmRemoveAll = false
                withAnimation(.snappy(duration: 0.2)) { store.removeAllCurrent() }
            } label: { Text("삭제") }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .card()
    }

    // MARK: List

    @ViewBuilder
    private var listArea: some View {
        if store.currentItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let active = store.activeItems
                    if !active.isEmpty {
                        itemsCard(active)
                    }
                    let done = store.doneItems
                    if !done.isEmpty {
                        doneSection(done)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func itemsCard(_ items: [ChecklistItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .card()
    }

    private func doneSection(_ done: [ChecklistItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showDone.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showDone ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("완료 \(done.count)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { store.archiveAllDone() }
                } label: {
                    Label("보관", systemImage: "archivebox")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .help("완료된 항목을 오늘 날짜로 보관함에 넣어요")
                Button("지우기") {
                    withAnimation(.snappy(duration: 0.2)) { store.clearDone() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 6)
            }
            .padding(.horizontal, 4)
            if showDone {
                itemsCard(done)
            }
        }
    }

    private func row(_ item: ChecklistItem) -> some View {
        ChecklistRow(
            item: item,
            isEditing: editingID == item.id,
            editingText: $editingText,
            editFocused: $editFocused,
            onToggle: { withAnimation(.snappy(duration: 0.2)) { store.toggle(item.id) } },
            onDelete: { withAnimation(.snappy(duration: 0.2)) { store.remove(item.id) } },
            onArchive: item.isDone ? { withAnimation(.snappy(duration: 0.2)) { store.archive(item.id) } } : nil,
            onBeginEdit: {
                editingID = item.id
                editingText = item.text
                editFocused = true
            },
            onCommitEdit: {
                if editingID == item.id {
                    store.update(item.id, text: editingText)
                    editingID = nil
                }
            },
            onCancelEdit: { if editingID == item.id { editingID = nil } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("할 일을 적어두세요")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("위 칸에 입력하고 Enter · 더블클릭으로 수정\n날짜가 바뀌면 전날 목록은 보관함으로 옮겨져요")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Archive

    @ViewBuilder
    private var archiveArea: some View {
        let days = store.archiveDays
        if days.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("보관된 항목이 없어요")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("하루가 지나면 그날의 목록이 날짜별로 쌓이고,\n완료한 항목은 \"보관\"으로 바로 넣을 수 있어요")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(days) { day in
                        archiveDayCard(day)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func archiveDayCard(_ day: ArchiveDay) -> some View {
        let collapsed = collapsedDays.contains(day.day)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if collapsed { collapsedDays.remove(day.day) } else { collapsedDays.insert(day.day) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                        Text(archiveDayTitle(day.date))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text("완료 \(day.doneCount) · 미완료 \(day.openCount)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { store.removeArchive(day: day.day) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("이 날짜의 보관 항목 삭제")
            }
            .padding(.horizontal, 4)
            if !collapsed {
                VStack(spacing: 0) {
                    ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                        ArchivedRow(item: item,
                                    onRestore: { withAnimation(.snappy(duration: 0.2)) { store.restore(item.id) } },
                                    onDelete: { withAnimation(.snappy(duration: 0.2)) { store.remove(item.id) } })
                        if index < day.items.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .card()
            }
        }
    }

    private func archiveDayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatted: String
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatted = date.formatted(.dateTime.month().day().weekday(.abbreviated))
        } else {
            formatted = date.formatted(.dateTime.year().month().day().weekday(.abbreviated))
        }
        if calendar.isDateInToday(date) { return "오늘 · " + formatted }
        if calendar.isDateInYesterday(date) { return "어제 · " + formatted }
        return formatted
    }
}

struct ArchivedRow: View {
    let item: ChecklistItem
    let onRestore: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(item.isDone ? Color.accentColor.opacity(0.7) : Color.secondary)
            Text(item.text)
                .font(.system(size: 13))
                .strikethrough(item.isDone, color: .secondary)
                .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button(action: onRestore) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("오늘 목록으로 되돌리기")
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("삭제")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Theme.hoverFill(scheme) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(action: onRestore) { Label("오늘 목록으로 되돌리기", systemImage: "arrow.uturn.backward") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("삭제", systemImage: "trash") }
        }
    }
}

struct ChecklistRow: View {
    let item: ChecklistItem
    let isEditing: Bool
    @Binding var editingText: String
    var editFocused: FocusState<Bool>.Binding
    let onToggle: () -> Void
    let onDelete: () -> Void
    var onArchive: (() -> Void)? = nil
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            if isEditing {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(editFocused)
                    .onSubmit(onCommitEdit)
                    .onExitCommand(perform: onCancelEdit)
                    .onChange(of: editFocused.wrappedValue) { _, focused in
                        if !focused { onCommitEdit() }
                    }
            } else {
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onBeginEdit)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if let onArchive {
                    Button(action: onArchive) {
                        Image(systemName: "archivebox.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("보관함(오늘 날짜)으로 보관")
                }
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("삭제")
            }
            .opacity(hovering && !isEditing ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hovering ? Theme.hoverFill(scheme) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(action: onBeginEdit) { Label("수정", systemImage: "pencil") }
            Button(action: onToggle) { Label(item.isDone ? "완료 취소" : "완료", systemImage: "checkmark.circle") }
            if let onArchive {
                Button(action: onArchive) { Label("보관", systemImage: "archivebox") }
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("삭제", systemImage: "trash") }
        }
    }
}
