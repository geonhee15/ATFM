import SwiftUI

/// 메모 tab: 미니 메모 (scratch notes) and 스토리보드 (video planning) as sub-sections.
struct MemoView: View {
    var notes: QuickNotesStore
    var storyboards: StoryboardStore
    @State private var section: String

    init(notes: QuickNotesStore, storyboards: StoryboardStore) {
        self.notes = notes
        self.storyboards = storyboards
        let env = ProcessInfo.processInfo.environment["ATFM_DEBUG_MEMO"]
        _section = State(initialValue: env ?? UserDefaults.standard.string(forKey: "memoSection") ?? "notes")
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $section) {
                Text("미니 메모").tag("notes")
                Text("스토리보드").tag("storyboard")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 20)
            .onChange(of: section) { _, value in UserDefaults.standard.set(value, forKey: "memoSection") }
            if section == "storyboard" {
                ScrollView {
                    StoryboardView(store: storyboards)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            } else {
                QuickNotesView(store: notes)
            }
        }
    }
}
