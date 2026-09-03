import AppKit
import Observation
import SystemConfiguration
import Darwin

struct AppNetworkUsage: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    let pid: pid_t
    var inRate: Double      // bytes per second
    var outRate: Double
    var processCount: Int
    var totalRate: Double { inRate + outRate }
}

/// Interface throughput (getifaddrs counters) plus per-app traffic streamed from `nettop -P -d`.
@MainActor
@Observable
final class NetworkMonitor {
    static let historyLength = 60
    private static let nettopInterval: Double = 2

    var downloadRate: Double = 0
    var uploadRate: Double = 0
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
    var primaryInterface: String?
    var interfaceKind: String?
    var localIPv4: String?
    var apps: [AppNetworkUsage] = []
    var perAppAvailable = true
    var sessionDownloaded: UInt64 = 0
    var sessionUploaded: UInt64 = 0
    var isActive = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCounters: [String: (rx: UInt64, tx: UInt64)] = [:]
    @ObservationIgnored private var lastSampleTime: TimeInterval?
    @ObservationIgnored private var nettop: Process?
    @ObservationIgnored private var nettopBuffer = Data()
    @ObservationIgnored private var pendingRows: [(pid: pid_t, bytesIn: UInt64, bytesOut: UInt64)] = []
    @ObservationIgnored private var blockIndex = 0
    @ObservationIgnored private let resolver: ProcessIdentityResolver

    init(resolver: ProcessIdentityResolver) {
        self.resolver = resolver
    }

    func setActive(_ active: Bool) {
        if active { start() } else { stop() }
    }

    // MARK: Lifecycle

    private func start() {
        guard timer == nil else { return }
        isActive = true
        refreshInterfaceInfo()
        lastCounters = [:]
        lastSampleTime = nil
        sampleInterfaces()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleInterfaces() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        startNettop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        stopNettop()
        isActive = false
    }

    // MARK: Interface counters

    private func sampleInterfaces() {
        let counters = Self.readCounters()
        let now = ProcessInfo.processInfo.systemUptime
        if let lastTime = lastSampleTime {
            let dt = max(0.1, now - lastTime)
            var rx: UInt64 = 0, tx: UInt64 = 0
            for (name, value) in counters {
                guard let prev = lastCounters[name] else { continue }
                rx += Self.delta(value.rx, prev.rx)
                tx += Self.delta(value.tx, prev.tx)
            }
            downloadRate = Double(rx) / dt
            uploadRate = Double(tx) / dt
            sessionDownloaded += rx
            sessionUploaded += tx
            Self.push(&downloadHistory, downloadRate)
            Self.push(&uploadHistory, uploadRate)
        }
        lastCounters = counters
        lastSampleTime = now
    }

    /// Handles 32-bit wraparound of if_data counters.
    private static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        new >= old ? new - old : new &+ (UInt64(UInt32.max) - old) &+ 1
    }

    private static func readCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [:] }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let dataPtr = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en"), (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
        }
        return result
    }

    private static func ipv4Address(of interface: String) -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == interface else { continue }
            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            return String(cString: buffer)
        }
        return nil
    }

    private func refreshInterfaceInfo() {
        var primary: String?
        if let store = SCDynamicStoreCreate(nil, "ATFM" as CFString, nil, nil),
           let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primary = dict["PrimaryInterface"] as? String
        }
        primaryInterface = primary
        interfaceKind = nil
        if let primary, let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in interfaces {
                guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String?, bsd == primary else { continue }
                if let display = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                    interfaceKind = display
                } else if let type = SCNetworkInterfaceGetInterfaceType(iface) as String? {
                    interfaceKind = type == "IEEE80211" ? "Wi-Fi" : type
                }
                break
            }
        }
        localIPv4 = primary.flatMap { Self.ipv4Address(of: $0) }
    }

    // MARK: nettop (per-app traffic)

    private func startNettop() {
        guard nettop == nil else { return }
        // nettop block-buffers its stdout when it is a pipe (nothing arrives for several seconds),
        // so run it under `script` to give it a pseudo-TTY and get line-buffered output.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/usr/bin/nettop",
                             "-P", "-x", "-d", "-L", "0", "-s", "\(Int(Self.nettopInterval))", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(data) }
            }
        }
        nettopBuffer = Data()
        pendingRows = []
        blockIndex = 0
        process.terminationHandler = { p in
            NSLog("ATFM nettop: exited status %d reason %d", p.terminationStatus, p.terminationReason.rawValue)
        }
        do {
            try process.run()
            nettop = process
            perAppAvailable = true
            NSLog("ATFM nettop: started pid %d", process.processIdentifier)
        } catch {
            perAppAvailable = false
            NSLog("ATFM: nettop failed to start: \(error)")
        }
    }

    private func stopNettop() {
        guard let process = nettop else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            // Kill the whole `script` + nettop pair.
            kill(-process.processIdentifier, SIGTERM)
            process.terminate()
        }
        nettop = nil
    }

    private func consume(_ data: Data) {
        if ProcessInfo.processInfo.environment["ATFM_DEBUG_NETTOP"] != nil {
            NSLog("ATFM nettop: got %d bytes, block %d, pending %d", data.count, blockIndex, pendingRows.count)
        }
        nettopBuffer.append(data)
        // Split on raw newline bytes and decode each line lossily: nettop truncates process names at a
        // byte boundary, so a chunk can contain invalid UTF-8 and strict decoding would drop everything.
        while let newline = nettopBuffer.firstIndex(of: 0x0A) {
            let lineData = nettopBuffer[nettopBuffer.startIndex..<newline]
            nettopBuffer.removeSubrange(nettopBuffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            handle(line: line)
        }
    }

    private func handle(line: String) {
        if line.hasPrefix(",") {
            finishBlock()
            blockIndex += 1
            return
        }
        // `script` may echo a ^D marker when stdin hits EOF; skip anything that is not a data row.
        guard line.contains(",") else { return }
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return }
        let ident = parts[0]
        guard let dot = ident.lastIndex(of: "."), let pid = pid_t(ident[ident.index(after: dot)...]) else { return }
        let bytesIn = UInt64(parts[1]) ?? 0
        let bytesOut = UInt64(parts[2]) ?? 0
        pendingRows.append((pid, bytesIn, bytesOut))
    }

    private func finishBlock() {
        defer { pendingRows = [] }
        // Block 1 holds cumulative totals since boot; only later blocks are per-interval deltas.
        guard blockIndex >= 2 else { return }
        var groups: [String: AppNetworkUsage] = [:]
        for row in pendingRows where row.bytesIn > 0 || row.bytesOut > 0 {
            let identity = resolver.identity(for: row.pid)
            var usage = groups[identity.groupKey] ?? AppNetworkUsage(
                id: identity.groupKey, name: identity.name, bundlePath: identity.bundlePath,
                pid: identity.representativePID, inRate: 0, outRate: 0, processCount: 0
            )
            usage.inRate += Double(row.bytesIn) / Self.nettopInterval
            usage.outRate += Double(row.bytesOut) / Self.nettopInterval
            usage.processCount += 1
            groups[identity.groupKey] = usage
        }
        apps = groups.values.sorted { $0.totalRate > $1.totalRate }
    }

    private static func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
