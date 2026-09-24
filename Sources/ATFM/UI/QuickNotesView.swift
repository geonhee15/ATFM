import SwiftUI

struct QuickNotesView: View {
    @Bindable var store: QuickNotesStore
    @Environment(\.colorScheme) private var scheme
    @State private var confirmingDelete = false
    @State private var copied = false
    @State private var format = TextFormatState()
    @State private var focusRequest = 0
    @State private var handle = RichTextEditorHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chips
            editor
            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .onChange(of: store.selectedID) { _, _ in confirmingDelete = false }
    }

    private var header: some View {
        HStack {
            Text("미니 메모")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("자동 저장 · \(store.notes.count)개")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.notes) { note in
                        NoteChip(title: note.title, selected: note.id == store.selectedID) {
                            store.select(note.id)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            Button {
                store.addNote()
                focusRequest += 1
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.chipFill(scheme)))
            }
            .buttonStyle(.plain)
            .help("새 메모")
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            formatBar
            Divider().padding(.horizontal, 10)
            ZStack(alignment: .topLeading) {
                RichTextEditor(noteID: store.selectedID, content: store.selected?.attributed ?? NSAttributedString(),
                               onChange: { store.update(attributed: $0) },
                               onFormatChange: { state in if state != format { format = state } },
                               focusRequest: focusRequest, handle: handle)
                if store.selectedText.isEmpty {
                    Text("잠깐 적어둘 것…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    /// Google-Docs style formatting: ⌘B · ⌘I · ⌘U · ⌘⇧X, mirrored as buttons.
    private var formatBar: some View {
        HStack(spacing: 4) {
            formatButton("bold", on: format.bold, help: "굵게 ⌘B") { handle.bold() }
            formatButton("italic", on: format.italic, help: "기울임 ⌘I") { handle.italic() }
            formatButton("underline", on: format.underline, help: "밑줄 ⌘U") { handle.underline() }
            formatButton("strikethrough", on: format.strikethrough, help: "취소선 ⌘⇧X") { handle.strikethrough() }
            Spacer()
            Button { handle.clear() } label: {
                Image(systemName: "textformat.abc.dottedunderline").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("서식 지우기 ⌘⇧\\")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func formatButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Theme.accent.opacity(0.18) : Color.clear))
                .foregroundStyle(on ? Theme.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let note = store.selected {
                Text(Self.relative(note.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("\(note.text.count)자")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
            if confirmingDelete {
                Text("이 메모를 지울까요?")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("삭제", role: .destructive) {
                    if let id = store.selectedID { store.delete(id) }
                    confirmingDelete = false
                }
                .controlSize(.small)
                Button("취소") { confirmingDelete = false }
                    .controlSize(.small)
            } else {
                Button {
                    copyCurrent()
                } label: {
                    Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .disabled(store.selectedText.isEmpty)
                .help("메모 전체를 클립보드에 복사")
                Button {
                    confirmingDelete = true
                } label: {
                    Label("삭제", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("이 메모 삭제")
            }
        }
        .padding(.horizontal, 4)
    }

    private func copyCurrent() {
        let text = store.selectedText
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let attributed = store.selected?.attributed, store.selected?.rich != nil,
           let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "방금 수정" }
        if seconds < 3600 { return "\(Int(seconds / 60))분 전 수정" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))시간 전 수정" }
        let f = DateFormatter()
        f.dateFormat = "M월 d일 HH:mm 수정"
        return f.string(from: date)
    }
}

private struct NoteChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .frame(maxWidth: 120)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Theme.accent : Color.primary)
                .background(
                    Capsule().fill(selected ? Theme.accent.opacity(0.16) : Theme.chipFill(scheme))
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
