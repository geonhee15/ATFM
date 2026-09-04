import AppKit
import Observation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, model }
    let id: UUID
    let role: Role
    var text: String
    let date: Date
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
    private static let base = "https://generativelanguage.googleapis.com/v1beta"
    static let systemInstruction = "You are a concise assistant living in a small macOS menu-bar app. Answer briefly, use Markdown sparingly, and reply in the language the user writes in."

    static func stream(apiKey: String, model: String, history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
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
                    let body: [String: Any] = [
                        "systemInstruction": ["parts": [["text": systemInstruction]]],
                        "contents": contents,
                        "generationConfig": ["temperature": 0.7],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
                    if http.statusCode != 200 {
                        var raw = ""
                        for try await line in bytes.lines { raw += line }
                        throw GeminiError.http(http.statusCode, errorMessage(from: raw))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let feedback = object["promptFeedback"] as? [String: Any],
                           let reason = feedback["blockReason"] as? String {
                            throw GeminiError.blocked(reason)
                        }
                        if let text = extractText(object), !text.isEmpty {
                            continuation.yield(text)
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

    private static func errorMessage(from raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return raw.isEmpty ? "알 수 없는 오류" : String(raw.prefix(200))
    }
}

/// Chat state + persistence for the 간편 AI tab. Keeps at most `maxConversations` threads.
@MainActor
@Observable
final class GeminiChat {
    static let maxConversations = 20
    static let defaultModel = "gemini-2.5-flash"
    static let presetModels = ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
    private static let apiKeyKey = "geminiAPIKey"
    private static let modelKey = "geminiModel"
    private static let contextMessages = 40

    private(set) var conversations: [Conversation] = []
    var currentID: UUID?
    var draft = ""
    var isStreaming = false
    var errorText: String?
    var availableModels: [String] = []
    var isLoadingModels = false
    var showKeyEditor = false
    private(set) var apiKey: String
    private(set) var model: String

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

    func refreshModels() {
        guard hasAPIKey, !isLoadingModels else { return }
        isLoadingModels = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await GeminiAPI.listModels(apiKey: apiKey)
                availableModels = models
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            isLoadingModels = false
        }
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
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in GeminiAPI.stream(apiKey: apiKey, model: model, history: history) {
                    appendText(chunk, toMessage: replyID, in: conversationID)
                }
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
            finishStreaming(replyID: replyID, in: conversationID)
        }
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

    private func finishStreaming(replyID: UUID, in conversationID: UUID) {
        isStreaming = false
        streamTask = nil
        if let i = index(of: conversationID),
           let j = conversations[i].messages.firstIndex(where: { $0.id == replyID }),
           conversations[i].messages[j].text.isEmpty {
            // Nothing came back (error or cancel): drop the empty placeholder.
            conversations[i].messages.remove(at: j)
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
