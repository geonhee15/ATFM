import SwiftUI
import Translation

struct TranslatorView: View {
    @Bindable var model: TranslatorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                AppleTranslationHost(model: model) { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            languageRow
            sourceCard
            resultCard
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private var header: some View {
        HStack {
            Text("번역")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $model.engine) {
                ForEach(TranslatorModel.Engine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 190)
        }
        .padding(.horizontal, 2)
    }

    private var languageRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { model.sourceCode ?? "auto" }, set: { model.sourceCode = $0 == "auto" ? nil : $0 })) {
                Text("자동 감지").tag("auto")
                Divider()
                ForEach(TranslateLanguage.all) { language in Text(language.name).tag(language.code) }
            }
            .labelsHidden()
            .controlSize(.small)
            Button {
                model.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.sourceCode == nil ? Color.secondary.opacity(0.4) : Theme.accent)
            .disabled(model.sourceCode == nil)
            .help(model.sourceCode == nil ? "자동 감지일 땐 바꿀 수 없어요" : "언어 바꾸기")
            Picker("", selection: $model.targetCode) {
                ForEach(TranslateLanguage.all) { language in Text(language.name).tag(language.code) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.sourceText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 84, maxHeight: 150)
                if model.sourceText.isEmpty {
                    Text("번역할 글을 적거나 붙여넣으세요 · ⌘↩ 번역")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.pasteFromClipboard()
                } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if !model.sourceText.isEmpty {
                    Button {
                        model.clear()
                    } label: {
                        Label("지우기", systemImage: "xmark.circle").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.sourceText.count)자")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button {
                    model.translate()
                } label: {
                    if model.status == .working {
                        ProgressView().controlSize(.mini).frame(width: 44)
                    } else {
                        Text("번역").font(.system(size: 12, weight: .semibold)).frame(width: 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .disabled(!model.canTranslate)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card()
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(TranslateLanguage.named(model.targetCode))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                statusText
                if !model.result.isEmpty {
                    Button {
                        model.copyResult()
                    } label: {
                        Label(model.copied ? "복사됨" : "복사", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.copied ? Color.green : Theme.accent)
                }
            }
            if model.result.isEmpty {
                Text(model.status == .working ? "번역 중…" : "번역 결과가 여기에 나와요")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                Text(model.result)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.status {
        case .done(let engine):
            Text(engine).font(.system(size: 10)).foregroundStyle(.tertiary)
        case .failed(let message):
            HStack(spacing: 6) {
                Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(3)
                if message == TranslatorModel.needsLanguagePackMessage {
                    Button("설정 열기") { model.openLanguageSettings() }.controlSize(.mini)
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Hosts Apple's on-device translation session; re-runs whenever the model bumps `appleRequest`.
@available(macOS 15.0, *)
private struct AppleTranslationHost<Content: View>: View {
    let model: TranslatorModel
    @ViewBuilder let content: () -> Content
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        content()
            .onChange(of: model.appleRequest) { _, _ in
                let source = model.sourceCode.map { Locale.Language(identifier: $0) }
                let target = Locale.Language(identifier: model.targetCode)
                if configuration?.source == source, configuration?.target == target {
                    configuration?.invalidate()
                } else {
                    configuration = TranslationSession.Configuration(source: source, target: target)
                }
            }
            .translationTask(configuration) { session in
                let text = model.sourceText
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let target = Locale.Language(identifier: model.targetCode)
                let availability = LanguageAvailability()
                let status: LanguageAvailability.Status?
                if let code = model.sourceCode {
                    status = await availability.status(from: Locale.Language(identifier: code), to: target)
                } else {
                    status = try? await availability.status(for: text, to: target)
                }
                if status == .unsupported {
                    model.fail("Apple 번역이 지원하지 않는 언어 조합이에요. Gemini로 바꿔 보세요.")
                    return
                }
                do {
                    if status != .installed {
                        // The language pack download sheet needs an active app to show up.
                        NSApp.activate(ignoringOtherApps: true)
                        try await session.prepareTranslation()
                    }
                    let response = try await session.translate(text)
                    model.finish(response.targetText, engine: "Apple 번역")
                } catch {
                    model.fail(Self.describe(error, installed: status == .installed))
                }
            }
    }

    private static func describe(_ error: Error, installed: Bool) -> String {
        if !installed {
            return TranslatorModel.needsLanguagePackMessage
        }
        return "Apple 번역 실패: \(error.localizedDescription)"
    }
}
