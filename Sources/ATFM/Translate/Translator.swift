import AppKit
import Observation

struct TranslateLanguage: Identifiable, Equatable {
    let code: String      // BCP-47
    let name: String
    var id: String { code }

    static let all: [TranslateLanguage] = [
        .init(code: "ko", name: "한국어"), .init(code: "en", name: "English"), .init(code: "ja", name: "日本語"),
        .init(code: "zh-Hans", name: "中文(简体)"), .init(code: "zh-Hant", name: "中文(繁體)"), .init(code: "es", name: "Español"),
        .init(code: "fr", name: "Français"), .init(code: "de", name: "Deutsch"), .init(code: "it", name: "Italiano"),
        .init(code: "pt", name: "Português"), .init(code: "ru", name: "Русский"), .init(code: "vi", name: "Tiếng Việt"),
        .init(code: "th", name: "ไทย"), .init(code: "id", name: "Bahasa Indonesia"), .init(code: "ar", name: "العربية"),
        .init(code: "hi", name: "हिन्दी"), .init(code: "tr", name: "Türkçe"), .init(code: "nl", name: "Nederlands"),
        .init(code: "pl", name: "Polski"), .init(code: "uk", name: "Українська"),
    ]

    static func named(_ code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }
}

/// 번역 tab. Apple's on-device Translation framework (macOS 15+) drives the actual work from the view
/// (its session only exists inside SwiftUI's translationTask); Gemini is the online alternative.
@MainActor
@Observable
final class TranslatorModel {
    enum Engine: String, CaseIterable, Identifiable {
        case apple, gemini
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apple: return "Apple (오프라인)"
            case .gemini: return "Gemini"
            }
        }
    }

    enum Status: Equatable {
        case idle, working
        case done(String)          // engine label
        case failed(String)
    }

    var sourceText = ""
    var sourceCode: String? {      // nil = auto detect
        didSet { UserDefaults.standard.set(sourceCode ?? "", forKey: Self.sourceKey) }
    }
    var targetCode: String {
        didSet { UserDefaults.standard.set(targetCode, forKey: Self.targetKey) }
    }
    var engine: Engine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Self.engineKey) }
    }
    private(set) var result = ""
    private(set) var status: Status = .idle
    private(set) var copied = false
    /// Bumped to ask the Apple translation host (in the view) to run once more.
    private(set) var appleRequest = 0

    @ObservationIgnored private var geminiTask: Task<Void, Never>?
    private static let sourceKey = "translateSource"
    private static let targetKey = "translateTarget"
    private static let engineKey = "translateEngine"

    init() {
        let storedSource = UserDefaults.standard.string(forKey: Self.sourceKey) ?? ""
        sourceCode = storedSource.isEmpty ? nil : storedSource
        targetCode = UserDefaults.standard.string(forKey: Self.targetKey) ?? "ko"
        if let stored = Engine(rawValue: UserDefaults.standard.string(forKey: Self.engineKey) ?? "") {
            engine = stored
        } else {
            // First run: Gemini when a key is already set (Apple needs language packs downloaded first).
            let hasGeminiKey = !(UserDefaults.standard.string(forKey: "geminiAPIKey") ?? "").isEmpty
            engine = hasGeminiKey ? .gemini : .apple
        }
        if #unavailable(macOS 15.0), engine == .apple { engine = .gemini }
    }

    static let needsLanguagePackMessage = "언어 파일이 아직 없어요. 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 내려받거나, 위의 Gemini를 쓰세요."

    func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    var canTranslate: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status != .working }

    func translate() {
        guard canTranslate else { return }
        status = .working
        result = ""
        switch engine {
        case .apple:
            appleRequest += 1
        case .gemini:
            geminiTask?.cancel()
            let text = sourceText
            let target = TranslateLanguage.named(targetCode)
            let source = sourceCode.map(TranslateLanguage.named)
            geminiTask = Task { [weak self] in
                do {
                    let translated = try await GeminiQuick.translate(text, to: target, from: source)
                    guard !Task.isCancelled else { return }
                    self?.finish(translated, engine: "Gemini")
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error.localizedDescription)
                }
            }
        }
    }

    func finish(_ text: String, engine: String) {
        result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        status = .done(engine)
    }

    func fail(_ message: String) {
        status = .failed(message)
    }

    func swapLanguages() {
        guard let source = sourceCode else { return }
        sourceCode = targetCode
        targetCode = source
        if !result.isEmpty {
            sourceText = result
            result = ""
            status = .idle
        }
    }

    func clear() {
        sourceText = ""
        result = ""
        status = .idle
    }

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            sourceText = text
        }
    }

    func copyResult() {
        guard !result.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { self?.copied = false }
        }
    }
}

/// One-shot Gemini call with the key/model the 간편 AI tab stores.
enum GeminiQuick {
    struct QuickError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func translate(_ text: String, to target: String, from source: String?) async throws -> String {
        let prompt = """
        Translate the text between the markers into \(target)\(source.map { " (source language: \($0))" } ?? "").
        Output only the translation, no explanations, keep line breaks and formatting.
        <<<
        \(text)
        >>>
        """
        return try await generate(prompt: prompt)
    }

    static func generate(prompt: String) async throws -> String {
        let key = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        guard !key.isEmpty else { throw QuickError(message: "Gemini API 키가 없어요. 간편 AI 탭에서 먼저 넣어 주세요.") }
        let model = UserDefaults.standard.string(forKey: "geminiModel") ?? "gemini-flash-latest"
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw QuickError(message: "잘못된 모델 이름")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.2],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }.flatMap { $0["message"] as? String } ?? "HTTP \(code)"
            throw QuickError(message: "Gemini 요청 실패: \(message)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw QuickError(message: "Gemini 응답을 읽지 못했어요")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw QuickError(message: "Gemini가 빈 답을 보냈어요") }
        return text
    }
}
