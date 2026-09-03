import Foundation
import Observation

/// Simple bandwidth test against Cloudflare's speed endpoints (user-triggered only).
@MainActor
@Observable
final class SpeedTester {
    enum Phase: Equatable {
        case idle, ping, download, upload, done
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "측정 전"
            case .ping: return "지연 시간 측정 중…"
            case .download: return "다운로드 측정 중…"
            case .upload: return "업로드 측정 중…"
            case .done: return "측정 완료"
            case .failed(let msg): return "실패: \(msg)"
            }
        }
    }

    var phase: Phase = .idle
    var pingMs: Double?
    var downloadMbps: Double?
    var uploadMbps: Double?
    var liveMbps: Double = 0
    var lastRun: Date?

    var isRunning: Bool {
        switch phase {
        case .ping, .download, .upload: return true
        default: return false
        }
    }

    private static let base = "https://speed.cloudflare.com"
    private static let budget: TimeInterval = 7

    func run() {
        guard !isRunning else { return }
        Task { await runAll() }
    }

    private func runAll() async {
        pingMs = nil
        downloadMbps = nil
        uploadMbps = nil
        liveMbps = 0
        do {
            phase = .ping
            pingMs = try await measurePing()
            phase = .download
            downloadMbps = try await measureDownload()
            phase = .upload
            uploadMbps = try await measureUpload()
            phase = .done
            lastRun = Date()
        } catch {
            phase = .failed(error.localizedDescription)
        }
        liveMbps = 0
    }

    private func measurePing() async throws -> Double {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var samples: [Double] = []
        for _ in 0..<5 {
            var request = URLRequest(url: URL(string: Self.base + "/__down?bytes=0")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let start = Date()
            _ = try await session.data(for: request)
            samples.append(Date().timeIntervalSince(start) * 1000)
        }
        // First sample includes the TLS handshake; use the best of the rest.
        return samples.dropFirst().min() ?? samples[0]
    }

    private func measureDownload() async throws -> Double {
        let request = URLRequest(url: URL(string: Self.base + "/__down?bytes=250000000")!)
        let result = try await ThroughputSession.run(request: request, body: nil, budget: Self.budget) { [weak self] bps in
            Task { @MainActor in self?.liveMbps = bps * 8 / 1e6 }
        }
        guard result.seconds > 0, result.bytes > 0 else { throw SpeedTestError.noData }
        return Double(result.bytes) * 8 / result.seconds / 1e6
    }

    private func measureUpload() async throws -> Double {
        var request = URLRequest(url: URL(string: Self.base + "/__up")!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let payload = Data(count: 80 * 1024 * 1024)
        let result = try await ThroughputSession.run(request: request, body: payload, budget: Self.budget) { [weak self] bps in
            Task { @MainActor in self?.liveMbps = bps * 8 / 1e6 }
        }
        guard result.seconds > 0, result.bytes > 0 else { throw SpeedTestError.noData }
        return Double(result.bytes) * 8 / result.seconds / 1e6
    }
}

enum SpeedTestError: LocalizedError {
    case noData
    var errorDescription: String? { "데이터를 받지 못했어요" }
}

/// Runs one transfer for at most `budget` seconds and reports how many bytes moved in that time.
private final class ThroughputSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { let bytes: Int64; let seconds: Double }

    private let budget: TimeInterval
    private let onProgress: @Sendable (Double) -> Void
    private var start = Date()
    private var lastReport = Date()
    private var bytes: Int64 = 0
    private var finished = false
    private var continuation: CheckedContinuation<Result, Error>?
    private let lock = NSLock()

    private init(budget: TimeInterval, onProgress: @escaping @Sendable (Double) -> Void) {
        self.budget = budget
        self.onProgress = onProgress
    }

    static func run(request: URLRequest, body: Data?, budget: TimeInterval,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let delegate = ThroughputSession(budget: budget, onProgress: onProgress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = budget + 5
        config.timeoutIntervalForResource = budget + 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            delegate.start = Date()
            let task: URLSessionTask
            if let body {
                task = session.uploadTask(with: request, from: body)
            } else {
                task = session.dataTask(with: request)
            }
            task.resume()
        }
    }

    private func progressed(total: Int64, task: URLSessionTask) {
        bytes = total
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        if now.timeIntervalSince(lastReport) > 0.25, elapsed > 0 {
            lastReport = now
            onProgress(Double(bytes) / elapsed)
        }
        if elapsed >= budget { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        progressed(total: bytes + Int64(data.count), task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressed(total: totalBytesSent, task: task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let continuation else { return }
        finished = true
        let elapsed = Date().timeIntervalSince(start)
        if let error, bytes == 0 {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: Result(bytes: bytes, seconds: max(0.001, elapsed)))
        }
    }
}
