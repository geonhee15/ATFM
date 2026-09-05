import SwiftUI

struct GeminiChatView: View {
    @Bindable var chat: GeminiChat
    @State private var keyDraft = ""
    @State private var confirmDeleteAll = false
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            header
            if chat.showKeyEditor { keyCard }
            if confirmDeleteAll { deleteAllBar }
            messagesArea
            if let notice = chat.noticeText { noticeBar(notice) }
            if let error = chat.errorText { errorBar(error) }
            inputBar
        }
        .padding(.horizontal, 20)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("간편 AI")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(chat.model)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.chipFill(scheme)))
                .lineLimit(1)
            Spacer()
            headerMenu
        }
        .padding(.horizontal, 2)
    }

    private var modelChoices: [String] {
        var list = chat.availableModels.isEmpty ? GeminiChat.presetModels : chat.availableModels
        if !list.contains(chat.model) { list.insert(chat.model, at: 0) }
        return list
    }

    private var headerMenu: some View {
        Menu {
            Picker("모델", selection: Binding(get: { chat.model }, set: { chat.setModel($0) })) {
                ForEach(modelChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.inline)
            Button {
                chat.refreshModels()
            } label: { Label(chat.isLoadingModels ? "모델 목록 불러오는 중…" : "모델 목록 새로고침", systemImage: "arrow.clockwise") }
            .disabled(!chat.hasAPIKey || chat.isLoadingModels)
            Divider()
            Toggle("웹 검색(Google) 사용", isOn: Binding(get: { chat.useSearch }, set: { chat.setUseSearch($0) }))
            Divider()
            if !chat.sortedConversations.isEmpty {
                Menu("대화 기록 (\(chat.conversations.count)/\(GeminiChat.maxConversations))") {
                    ForEach(chat.sortedConversations) { conversation in
                        Button {
                            chat.select(conversation.id)
                        } label: {
                            if conversation.id == chat.currentID {
                                Label(conversation.title, systemImage: "checkmark")
                            } else {
                                Text(conversation.title)
                            }
                        }
                    }
                }
            }
            Button { chat.newConversation() } label: { Label("새 대화", systemImage: "plus") }
            Button(role: .destructive) { chat.deleteCurrent() } label: { Label("현재 대화 삭제", systemImage: "trash") }
                .disabled(chat.current == nil)
            Button(role: .destructive) { confirmDeleteAll = true } label: { Label("대화 전체 삭제…", systemImage: "trash.slash") }
                .disabled(chat.conversations.isEmpty)
            Divider()
            Button { chat.showKeyEditor = true } label: { Label("API 키 변경…", systemImage: "key") }
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

    // MARK: Key setup

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "key.fill").foregroundStyle(Theme.accent)
                Text("Gemini API 키").font(.system(size: 13, weight: .semibold))
                Spacer()
                if chat.hasAPIKey {
                    Button("닫기") { chat.showKeyEditor = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            SecureField(chat.hasAPIKey ? "새 키를 입력하면 교체됩니다" : "AIza… 로 시작하는 키", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(saveKey)
            HStack {
                Button("키 발급받기") {
                    NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/apikey")!)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                Spacer()
                Button("저장", action: saveKey)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("키는 이 Mac의 ATFM 설정에만 저장되고 Google 외의 곳으로 보내지 않아요.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .card()
    }

    private func saveKey() {
        chat.saveAPIKey(keyDraft)
        keyDraft = ""
        if chat.hasAPIKey { chat.refreshModels() }
    }

    private var deleteAllBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("대화 \(chat.conversations.count)개를 모두 삭제할까요?")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("취소") { confirmDeleteAll = false }
            Button(role: .destructive) {
                confirmDeleteAll = false
                chat.deleteAll()
            } label: { Text("삭제") }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .card()
    }

    // MARK: Messages

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let conversation = chat.current {
                        ForEach(conversation.messages) { message in
                            MessageBubble(
                                message: message,
                                isStreaming: chat.isStreaming && message.id == conversation.messages.last?.id,
                                onCopy: { chat.copyToPasteboard?(message.text) }
                            )
                            .id(message.id)
                        }
                    } else {
                        emptyState
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 4)
            }
            .onChange(of: chat.current?.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.current?.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.currentID) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Gemini에게 물어보세요")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Return 전송 · ⌥Return 줄바꿈 · 대화는 최근 \(GeminiChat.maxConversations)개까지 보관" + (chat.useSearch ? "\n웹 검색이 켜져 있어 날씨·뉴스 같은 최신 정보도 답해요" : ""))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            Spacer()
            Button {
                chat.noticeText = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .card(radius: 10)
    }

    private func errorBar(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(text).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
            Spacer()
            Button {
                chat.errorText = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .card(radius: 10)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("무엇이든 물어보세요", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { chat.send() }
            if chat.isStreaming {
                Button { chat.cancel() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .help("중단")
            } else {
                Button { chat.send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(chat.draft.isEmpty ? Color.secondary : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("보내기 (Return)")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .card(radius: 12)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onCopy: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.role == .user { Spacer(minLength: 40) }
            bubble
            if message.role == .model {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("답변 복사")
                .opacity(hovering && !message.text.isEmpty ? 1 : 0)
                Spacer(minLength: 40)
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.role == .user {
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent))
        } else {
            Group {
                if message.text.isEmpty && isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("생각 중…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(MarkdownLite.render(message.text))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let sources = message.sources, !sources.isEmpty {
                            Text(MarkdownLite.sourcesLine(sources, accent: Theme.accent))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .card(radius: 14)
        }
    }

}
