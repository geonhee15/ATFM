import SwiftUI

struct ChecklistView: View {
    @Bindable var store: ChecklistStore
    @State private var newText = ""
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var showDone = true
    @State private var confirmRemoveAll = false
    @FocusState private var inputFocused: Bool
    @FocusState private var editFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            header
            inputBar
            if confirmRemoveAll { removeAllBar }
            listArea
        }
        .padding(.horizontal, 20)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("체크리스트")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if !store.items.isEmpty {
                Text("\(store.doneItems.count)/\(store.items.count) 완료")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.chipFill(scheme)))
            }
            Spacer()
            Menu {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { store.clearDone() }
                } label: { Label("완료 항목 지우기", systemImage: "checkmark.circle") }
                .disabled(store.doneItems.isEmpty)
                Divider()
                Button(role: .destructive) { confirmRemoveAll = true } label: {
                    Label("전체 삭제…", systemImage: "trash")
                }
                .disabled(store.items.isEmpty)
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

    private var removeAllBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("항목 \(store.items.count)개를 모두 삭제할까요?")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("취소") { confirmRemoveAll = false }
            Button(role: .destructive) {
                confirmRemoveAll = false
                withAnimation(.snappy(duration: 0.2)) { store.removeAll() }
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
        if store.items.isEmpty {
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
                Button("지우기") {
                    withAnimation(.snappy(duration: 0.2)) { store.clearDone() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
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
            Text("위 칸에 입력하고 Enter · 더블클릭으로 수정")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ChecklistRow: View {
    let item: ChecklistItem
    let isEditing: Bool
    @Binding var editingText: String
    var editFocused: FocusState<Bool>.Binding
    let onToggle: () -> Void
    let onDelete: () -> Void
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

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering && !isEditing ? 1 : 0)
            .help("삭제")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hovering ? Theme.hoverFill(scheme) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(action: onBeginEdit) { Label("수정", systemImage: "pencil") }
            Button(action: onToggle) { Label(item.isDone ? "완료 취소" : "완료", systemImage: "checkmark.circle") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("삭제", systemImage: "trash") }
        }
    }
}
