import Foundation
import Network
import Observation

/// Loopback WebSocket server the "ATFM Bridge" WebExtension connects to. Gives Zen/Firefox (no
/// AppleScript) the same abilities the Chromium/Safari paths get through Apple Events: the tab list,
/// the active tab, and running JavaScript in tabs.
@MainActor
@Observable
final class BrowserBridge {
    struct Tab: Equatable {
        let id: Int
        let url: String
        let title: String
        let active: Bool
    }

    struct Client: Identifiable {
        let id: UUID
        var browser: String          // "zen" / "firefox"
        var version: String
        var tabs: [Tab] = []
        var activeTab: Tab?
        var updatedAt = Date()
        var name: String { browser == "zen" ? "Zen" : browser.capitalized }
    }

    struct ExecResult {
        let tabID: Int
        let url: String
        let value: String?
        let error: String?
    }

    static let port: UInt16 = 47831
    private(set) var clients: [Client] = []
    private(set) var isListening = false
    private(set) var lastError: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: NWConnection] = [:]
    @ObservationIgnored private var pending: [String: (Any) -> Void] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "atfm.bridge")

    var isConnected: Bool { !clients.isEmpty }
    var connectedNames: String { clients.map(\.name).joined(separator: " · ") }

    /// Every tab across connected browsers (url, title).
    var allTabs: [(url: String, title: String)] {
        clients.flatMap { $0.tabs.map { (url: $0.url, title: $0.title) } }
    }

    func client(named browser: String) -> Client? { clients.first { $0.browser == browser } }

    // MARK: Listening

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Bind to 127.0.0.1 only: nothing on the network can reach the bridge.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isListening = true; self?.lastError = nil
                    case .failed(let error): self?.isListening = false; self?.lastError = "브리지 포트 \(Self.port) 열기 실패: \(error.localizedDescription)"
                    case .cancelled: self?.isListening = false
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = "브리지 서버 시작 실패: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        clients.removeAll()
        isListening = false
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.drop(id)
                default: break
                }
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id)
    }

    private func drop(_ id: UUID) {
        connections[id]?.cancel()
        connections[id] = nil
        clients.removeAll { $0.id == id }
    }

    private func receive(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if metadata.opcode == .text, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor in self.handle(object, from: id) }
                } else if metadata.opcode == .close {
                    Task { @MainActor in self.drop(id) }
                    return
                }
            }
            if error == nil { self.receive(on: connection, id: id) } else { Task { @MainActor in self.drop(id) } }
        }
    }

    private func handle(_ message: [String: Any], from id: UUID) {
        switch message["type"] as? String {
        case "hello":
            let browser = (message["browser"] as? String ?? "firefox").lowercased()
            let version = message["version"] as? String ?? ""
            clients.removeAll { $0.id == id }
            clients.append(Client(id: id, browser: browser, version: version))
        case "tabs":
            guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
            let list = (message["tabs"] as? [[String: Any]] ?? []).map(Self.tab(from:))
            clients[index].tabs = list
            clients[index].activeTab = (message["active"] as? [String: Any]).map(Self.tab(from:)) ?? list.first { $0.active }
            clients[index].updatedAt = Date()
        case "result":
            if let requestID = message["id"] as? String, let handler = pending.removeValue(forKey: requestID) {
                handler(message["results"] ?? [])
            }
        default:
            break
        }
    }

    private static func tab(from object: [String: Any]) -> Tab {
        Tab(id: object["id"] as? Int ?? 0, url: object["url"] as? String ?? "", title: object["title"] as? String ?? "",
            active: object["active"] as? Bool ?? false)
    }

    // MARK: Sending

    private func send(_ object: [String: Any], to id: UUID) {
        guard let connection = connections[id], let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Runs `code` in every tab of every connected browser whose URL contains `needle`.
    func exec(_ code: String, needle: String, timeout: TimeInterval = 6, completion: @escaping @MainActor ([ExecResult], String?) -> Void) {
        guard !clients.isEmpty else { completion([], "브리지 확장이 연결되어 있지 않아요"); return }
        var collected: [ExecResult] = []
        var remaining = clients.count
        var timedOut = false
        for client in clients {
            let requestID = UUID().uuidString
            pending[requestID] = { results in
                guard !timedOut else { return }
                for item in (results as? [[String: Any]] ?? []) {
                    let value = item["value"]
                    let text: String?
                    if let string = value as? String { text = string } else if let value, !(value is NSNull) { text = "\(value)" } else { text = nil }
                    collected.append(ExecResult(tabID: item["tabId"] as? Int ?? 0, url: item["url"] as? String ?? "", value: text, error: item["error"] as? String))
                }
                remaining -= 1
                if remaining == 0 { completion(collected, nil) }
            }
            send(["type": "exec", "id": requestID, "needle": needle, "code": code], to: client.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pending.removeValue(forKey: requestID) != nil else { return }
                    timedOut = true
                    completion(collected, "브라우저 확장이 \(Int(timeout))초 안에 응답하지 않았어요")
                }
            }
        }
    }

    /// Runs `code` in the active tab of one browser and returns the first result.
    func execInActiveTab(of browser: String, code: String, timeout: TimeInterval = 4, completion: @escaping @MainActor (String?, String?) -> Void) {
        guard let client = client(named: browser), let tab = client.activeTab else { completion(nil, "활성 탭 정보가 없어요"); return }
        let requestID = UUID().uuidString
        pending[requestID] = { results in
            let first = (results as? [[String: Any]])?.first
            let value = first?["value"]
            let text = value as? String ?? (value.map { "\($0)" })
            completion(first?["error"] == nil ? text : nil, first?["error"] as? String)
        }
        send(["type": "exec", "id": requestID, "tabId": tab.id, "code": code], to: client.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending.removeValue(forKey: requestID) != nil else { return }
                completion(nil, "응답 없음")
            }
        }
    }

    func requestTabs() {
        for client in clients { send(["type": "tabs"], to: client.id) }
    }

    // MARK: Install helpers

    static var extensionFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("BrowserBridge") }
    static var xpi: URL? { Bundle.main.resourceURL?.appendingPathComponent("ATFM-Bridge.xpi") }
}
