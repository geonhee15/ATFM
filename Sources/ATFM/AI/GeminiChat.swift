import AppKit
import Observation

struct WebSource: Codable, Equatable {
    let title: String
    let uri: String
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, model }
    let id: UUID
    let role: Role
    var text: String
    let date: Date
    var sources: [WebSource]? = nil
}

enum GeminiStreamEvent {
    case text(String)
    case sources([WebSource])
}

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
}

enum GeminiError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case blocked(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "API 키가 없어요"
        case .http(let status, let message): return "요청 실패 (\(status)): \(message)"
        case .blocked(let reason): return "응답이 차단됐어요: \(reason)"
        case .badResponse: return "응답을 이해하지 못했어요"
        }
    }
}

/// Minimal Gemini REST client (streaming via server-sent events).
enum GeminiAPI {
    static var debugLog: (String) -> Void = { _ in }
    private static let base = "https://generativelanguage.googleapis.com/v1beta"
    static let systemInstruction = "You are a concise assistant living in a small macOS menu-bar app. Answer briefly, use Markdown sparingly (bold and short lists only), and reply in the language the user writes in. When a search tool is available, use it for anything time-sensitive such as weather, news, prices or schedules instead of saying you cannot access real-time information."

    static func stream(apiKey: String, model: String, history: [ChatMessage], useSearch: Bool) -> AsyncThrowingStream<GeminiStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "\(base)/models/\(model):streamGenerateContent?alt=sse")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    request.timeoutInterval = 60
                    let contents: [[String: Any]] = history.map { message in
                        ["role": message.role == .user ? "user" : "model", "parts": [["text": message.text]]]
                    }
                    var body: [String: Any] = [
                        "systemInstruction": ["parts": [["text": systemInstruction]]],
                        "contents": contents,
                        "generationConfig": ["temperature": 0.7],
                    ]
                    if useSearch {
                        // Google Search grounding: lets the model look things up (weather, news, prices…).
                        body["tools"] = [["google_search": [String: Any]()]]
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    debugLog("stream: requesting")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
                    debugLog("stream: status \(http.statusCode)")
                    if http.statusCode != 200 {
                        var raw = ""
                        for try await line in bytes.lines { raw += line }
                        debugLog("stream: error body \(raw.count) chars")
                        throw GeminiError.http(http.statusCode, errorMessage(from: raw))
                    }
                    for try await line in bytes.lines {
                        debugLog("stream: line \(line.prefix(60))")
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let feedback = object["promptFeedback"] as? [String: Any],
                           let reason = feedback["blockReason"] as? String {
                            throw GeminiError.blocked(reason)
                        }
                        if let text = extractText(object), !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                        let sources = extractSources(object)
                        if !sources.isEmpty {
                            continuation.yield(.sources(sources))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func listModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "\(base)/models?pageSize=200")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
        guard http.statusCode == 200 else {
            throw GeminiError.http(http.statusCode, errorMessage(from: String(decoding: data, as: UTF8.self)))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { throw GeminiError.badResponse }
        return models.compactMap { model -> String? in
            guard let name = model["name"] as? String,
                  let methods = model["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }
        .filter { $0.hasPrefix("gemini") }
        .sorted()
    }

    private static func extractText(_ object: [String: Any]) -> String? {
        guard let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private static func extractSources(_ object: [String: Any]) -> [WebSource] {
        guard let candidates = object["candidates"] as? [[String: Any]],
              let metadata = candidates.first?["groundingMetadata"] as? [String: Any],
              let chunks = metadata["groundingChunks"] as? [[String: Any]] else { return [] }
        return chunks.compactMap { chunk in
            guard let web = chunk["web"] as? [String: Any], let uri = web["uri"] as? String else { return nil }
            let title = (web["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? uri
            return WebSource(title: title, uri: uri)
        }
    }

    private static func errorMessage(from raw: String) -> String {
        // Error bodies (and SSE error frames) may be a JSON object or an array of objects.
        guard let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            return raw.isEmpty ? "알 수 없는 오류" : String(raw.prefix(200))
        }
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first ?? [:]
        guard let error = object["error"] as? [String: Any], let message = error["message"] as? String else {
            return String(raw.prefix(200))
        }
        // Quota failures say which limit was hit (e.g. free-tier requests per day for this model).
        var quotaNotes: [String] = []
        for detail in error["details"] as? [[String: Any]] ?? [] {
            for violation in detail["violations"] as? [[String: Any]] ?? [] {
                if let id = violation["quotaId"] as? String { quotaNotes.append(id) }
            }
            if let retry = detail["retryDelay"] as? String { quotaNotes.append("retry in \(retry)") }
        }
        return quotaNotes.isEmpty ? message : message + " [" + quotaNotes.joined(separator: ", ") + "]"
    }
}

/// Chat state + persistence for the 간편 AI tab. Keeps at most `maxConversations` threads.
@MainActor
@Observable
final class GeminiChat {
    static let maxConversations = 20
    static let defaultModel = "gemini-flash-latest"
    static let presetModels = ["gemini-flash-latest", "gemini-flash-lite-latest", "gemini-pro-latest"]
    private static let apiKeyKey = "geminiAPIKey"
    private static let modelKey = "geminiModel"
    private static let searchKey = "geminiUseSearch"
    private static let contextMessages = 40

    private(set) var conversations: [Conversation] = []
    var currentID: UUID?
    var draft = ""
    var isStreaming = false
    var errorText: String?
    var availableModels: [String] = []
    var isLoadingModels = false
    var showKeyEditor = false
    var noticeText: String?
    private(set) var apiKey: String
    private(set) var model: String
    private(set) var useSearch: Bool

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// Set by the app so copies from the chat are not re-recorded by the clipboard monitor.
    @ObservationIgnored var copyToPasteboard: ((String) -> Void)?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("gemini-chats.json")
        let defaults = UserDefaults.standard
        apiKey = defaults.string(forKey: Self.apiKeyKey) ?? ""
        model = defaults.string(forKey: Self.modelKey) ?? Self.defaultModel
        useSearch = (defaults.object(forKey: Self.searchKey) as? Bool) ?? true
        load()
        currentID = conversations.first?.id
        showKeyEditor = apiKey.isEmpty
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    var current: Conversation? {
        guard let currentID else { return nil }
        return conversations.first { $0.id == currentID }
    }

    var sortedConversations: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Settings

    func saveAPIKey(_ key: String) {
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(apiKey, forKey: Self.apiKeyKey)
        showKeyEditor = apiKey.isEmpty
        errorText = nil
    }

    func setModel(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.modelKey)
    }

    func setUseSearch(_ on: Bool) {
        useSearch = on
        UserDefaults.standard.set(on, forKey: Self.searchKey)
    }

    /// Fetches the account's models; if the current one is not usable, switches to the best available.
    func refreshModels() {
        guard hasAPIKey, !isLoadingModels else { return }
        isLoadingModels = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await GeminiAPI.listModels(apiKey: apiKey)
                availableModels = models
                errorText = nil
                if !models.isEmpty, !models.contains(model), let pick = Self.bestModel(from: models) {
                    let previous = model
                    setModel(pick)
                    noticeText = "'\(previous)' 모델은 쓸 수 없어서 \(pick) 로 바꿨어요"
                }
            } catch {
                errorText = error.localizedDescription
            }
            isLoadingModels = false
        }
    }

    /// Prefers the newest general-purpose "flash" model, skipping lite/preview/experimental variants.
    nonisolated static func bestModel(from models: [String]) -> String? {
        func version(_ name: String) -> Double {
            guard let match = name.range(of: #"gemini-(\d+(?:\.\d+)?)"#, options: .regularExpression) else { return 0 }
            return Double(name[match].dropFirst("gemini-".count)) ?? 0
        }
        let excluded = ["lite", "tts", "image", "embedding", "exp", "preview", "audio", "live", "thinking",
                        "omni", "transcribe", "robotics", "computer-use", "latest"]
        let general = models.filter { name in !excluded.contains { name.contains($0) } }
        let flash = general.filter { $0.contains("flash") }.sorted { version($0) > version($1) }
        if let best = flash.first { return best }
        if let best = general.sorted(by: { version($0) > version($1) }).first { return best }
        return models.first
    }

    // MARK: Conversations

    func newConversation() {
        cancel()
        currentID = nil
        errorText = nil
    }

    func select(_ id: UUID) {
        cancel()
        currentID = id
        errorText = nil
    }

    func deleteCurrent() {
        guard let currentID else { return }
        cancel()
        conversations.removeAll { $0.id == currentID }
        self.currentID = conversations.sorted { $0.updatedAt > $1.updatedAt }.first?.id
        scheduleSave()
    }

    func deleteAll() {
        cancel()
        conversations = []
        currentID = nil
        scheduleSave()
    }

    // MARK: Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard hasAPIKey else { showKeyEditor = true; return }
        draft = ""
        errorText = nil

        let conversationID = ensureConversation(titleFrom: text)
        append(ChatMessage(id: UUID(), role: .user, text: text, date: Date()), to: conversationID)
        let replyID = UUID()
        append(ChatMessage(id: replyID, role: .model, text: "", date: Date()), to: conversationID)

        let history = Array((current?.messages ?? []).dropLast().suffix(Self.contextMessages))
        isStreaming = true
        noticeText = nil
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await runStream(history: history, useSearch: useSearch, replyID: replyID, in: conversationID)
            } catch GeminiError.http(400, let message) where useSearch && !Task.isCancelled {
                // The model may not support the search tool: retry once without it.
                resetText(of: replyID, in: conversationID)
                noticeText = "이 모델은 웹 검색을 지원하지 않아 검색 없이 답했어요 (\(message.prefix(80)))"
                await retry(history: history, useSearch: false, replyID: replyID, in: conversationID)
            } catch GeminiError.http(404, let message) where !Task.isCancelled {
                // Google retires models and names the replacement in the error: switch and resend.
                if let suggested = Self.suggestedModel(in: message, current: model) {
                    let previous = model
                    setModel(suggested)
                    resetText(of: replyID, in: conversationID)
                    noticeText = "'\(previous)' 모델은 더 이상 쓸 수 없어 \(suggested) 로 바꿔 다시 보냈어요"
                    await retry(history: history, useSearch: useSearch, replyID: replyID, in: conversationID)
                } else {
                    handleStreamError(GeminiError.http(404, message))
                }
            } catch GeminiError.http(503, _) where !Task.isCancelled {
                // Transient "high demand": wait a moment and try once more.
                resetText(of: replyID, in: conversationID)
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled {
                    await retry(history: history, useSearch: useSearch, replyID: replyID, in: conversationID)
                }
            } catch GeminiError.http(429, _) where useSearch && !Task.isCancelled {
                // Grounded requests have their own (smaller) quota: try once more without search.
                resetText(of: replyID, in: conversationID)
                noticeText = "검색을 포함한 요청이 한도에 걸려 검색 없이 다시 보냈어요"
                await retry(history: history, useSearch: false, replyID: replyID, in: conversationID)
            } catch {
                handleStreamError(error)
            }
            finishStreaming(replyID: replyID, in: conversationID)
        }
    }

    private func runStream(history: [ChatMessage], useSearch: Bool, replyID: UUID, in conversationID: UUID) async throws {
        for try await event in GeminiAPI.stream(apiKey: apiKey, model: model, history: history, useSearch: useSearch) {
            switch event {
            case .text(let chunk):
                appendText(chunk, toMessage: replyID, in: conversationID)
            case .sources(let sources):
                addSources(sources, toMessage: replyID, in: conversationID)
            }
        }
    }

    private func retry(history: [ChatMessage], useSearch: Bool, replyID: UUID, in conversationID: UUID) async {
        do {
            try await runStream(history: history, useSearch: useSearch, replyID: replyID, in: conversationID)
        } catch {
            handleStreamError(error)
        }
    }

    private func handleStreamError(_ error: Error) {
        guard !Task.isCancelled else { return }
        if case GeminiError.http(let status, let message) = error {
            switch status {
            case 429:
                errorText = "사용량 한도를 넘었어요 (모델: \(model)). 잠시 후 다시 보내거나 메뉴에서 다른 모델을 골라 주세요."
            case 404:
                errorText = "모델 '\(model)' 을 쓸 수 없어요. 메뉴에서 모델 목록을 새로고침해 다른 모델을 골라 주세요."
                refreshModels()   // picks a usable model automatically
            case 503:
                errorText = "모델이 지금 혼잡해요 (503). 잠시 후 다시 보내거나 다른 모델을 골라 주세요."
            default:
                errorText = "요청 실패 (\(status)): \(message.prefix(200))"
            }
        } else {
            errorText = error.localizedDescription
        }
    }

    /// Pulls "models/gemini-x.y-flash" out of Google's retirement message; returns the one that differs from `current`.
    nonisolated static func suggestedModel(in message: String, current: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"models/([A-Za-z0-9.\-]+)"#) else { return nil }
        let ns = message as NSString
        let names = regex.matches(in: message, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        return names.last(where: { $0 != current })
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        if isStreaming { isStreaming = false }
    }

    private func ensureConversation(titleFrom text: String) -> UUID {
        if let current { return current.id }
        let title = String(text.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        let conversation = Conversation(id: UUID(), title: title, createdAt: Date(), updatedAt: Date(), messages: [])
        conversations.append(conversation)
        currentID = conversation.id
        enforceLimit()
        return conversation.id
    }

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    private func append(_ message: ChatMessage, to conversationID: UUID) {
        guard let i = index(of: conversationID) else { return }
        conversations[i].messages.append(message)
        conversations[i].updatedAt = Date()
    }

    private func appendText(_ chunk: String, toMessage messageID: UUID, in conversationID: UUID) {
        guard let i = index(of: conversationID),
              let j = conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[i].messages[j].text += chunk
    }

    private func resetText(of messageID: UUID, in conversationID: UUID) {
        guard let i = index(of: conversationID),
              let j = conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[i].messages[j].text = ""
        conversations[i].messages[j].sources = nil
    }

    private func addSources(_ sources: [WebSource], toMessage messageID: UUID, in conversationID: UUID) {
        guard let i = index(of: conversationID),
              let j = conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        var merged = conversations[i].messages[j].sources ?? []
        for source in sources where !merged.contains(where: { $0.uri == source.uri }) {
            merged.append(source)
        }
        conversations[i].messages[j].sources = merged
    }

    private func finishStreaming(replyID: UUID, in conversationID: UUID) {
        isStreaming = false
        streamTask = nil
        if let i = index(of: conversationID),
           let j = conversations[i].messages.firstIndex(where: { $0.id == replyID }),
           conversations[i].messages[j].text.isEmpty {
            // Nothing came back (error, cancel, or an empty completion): drop the empty placeholder.
            conversations[i].messages.remove(at: j)
            if errorText == nil, !Task.isCancelled, noticeText == nil {
                noticeText = "빈 응답이 왔어요. 다시 보내거나 다른 모델을 골라 주세요."
            }
        }
        if let i = index(of: conversationID) { conversations[i].updatedAt = Date() }
        scheduleSave()
    }

    /// Drops the oldest conversations beyond the cap (oldest by last activity).
    private func enforceLimit() {
        guard conversations.count > Self.maxConversations else { return }
        let keep = Set(conversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxConversations).map(\.id))
        conversations.removeAll { !keep.contains($0.id) }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        conversations = (try? decoder.decode([Conversation].self, from: data)) ?? []
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = conversations
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
