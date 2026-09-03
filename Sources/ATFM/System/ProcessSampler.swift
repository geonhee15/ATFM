import AppKit
import Darwin

/// Resolves a pid to the "app" it belongs to (responsible process → NSRunningApplication),
/// so helper processes are grouped under their parent app like Activity Monitor does.
final class ProcessIdentityResolver {
    struct Identity {
        let groupKey: String
        let name: String
        let bundlePath: String?
        let bundleID: String?
        let representativePID: pid_t
        var isApp: Bool { bundlePath != nil }
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsibleFn: ResponsibleFn?
    private var cache: [pid_t: Identity] = [:]

    init() {
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            responsibleFn = unsafeBitCast(sym, to: ResponsibleFn.self)
        } else {
            responsibleFn = nil
        }
    }

    func forget(pidsNotIn alive: Set<pid_t>) {
        cache = cache.filter { alive.contains($0.key) }
    }

    func identity(for pid: pid_t) -> Identity {
        if let cached = cache[pid] { return cached }
        let responsible = responsiblePID(for: pid)
        let identity: Identity
        if let app = NSRunningApplication(processIdentifier: responsible), let name = app.localizedName {
            let key = app.bundleIdentifier ?? "pid:\(responsible)"
            identity = Identity(groupKey: "app:" + key, name: name, bundlePath: app.bundleURL?.path,
                                bundleID: app.bundleIdentifier, representativePID: responsible)
        } else if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            let key = app.bundleIdentifier ?? "pid:\(pid)"
            identity = Identity(groupKey: "app:" + key, name: name, bundlePath: app.bundleURL?.path,
                                bundleID: app.bundleIdentifier, representativePID: pid)
        } else if let (ancestor, app) = Self.ancestorApp(of: responsible), let name = app.localizedName {
            // e.g. a CLI tool spawned from a terminal or an Electron helper: group under the owning app.
            let key = app.bundleIdentifier ?? "pid:\(ancestor)"
            identity = Identity(groupKey: "app:" + key, name: name, bundlePath: app.bundleURL?.path,
                                bundleID: app.bundleIdentifier, representativePID: ancestor)
        } else {
            let path = Self.path(of: responsible) ?? Self.path(of: pid) ?? Self.name(of: pid) ?? "pid \(pid)"
            let name = pid == 0 ? "kernel_task" : (path as NSString).lastPathComponent
            identity = Identity(groupKey: "proc:" + (pid == 0 ? "kernel_task" : path), name: name,
                                bundlePath: nil, bundleID: nil, representativePID: responsible)
        }
        cache[pid] = identity
        return identity
    }

    private func responsiblePID(for pid: pid_t) -> pid_t {
        guard let responsibleFn else { return pid }
        let r = responsibleFn(pid)
        return r > 0 ? r : pid
    }

    /// Walks up the parent chain (at most 8 levels, stopping at launchd) looking for a GUI app.
    static func ancestorApp(of pid: pid_t) -> (pid_t, NSRunningApplication)? {
        var current = pid
        for _ in 0..<8 {
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.bundleURL != nil {
                return (parent, app)
            }
            current = parent
        }
        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n)))
    }
}

struct AppUsage: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    let bundleID: String?
    let pid: pid_t
    var cpuPercent: Double        // percent of the whole machine (all cores = 100)
    var memoryBytes: UInt64
    var energyMilliwatts: Double
    var processCount: Int
}

/// Samples CPU time, memory footprint and billed energy per process and aggregates per app.
final class ProcessSampler {
    private struct Snapshot {
        var cpuNanos: UInt64
        var energyNanojoules: UInt64
        var footprint: UInt64
        var time: TimeInterval
    }

    let resolver: ProcessIdentityResolver
    private var previous: [pid_t: Snapshot] = [:]
    private let timebase: mach_timebase_info_data_t
    private(set) var hasEnergyData = false

    init(resolver: ProcessIdentityResolver) {
        self.resolver = resolver
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = tb
    }

    private func nanos(fromMach value: UInt64) -> UInt64 {
        guard timebase.denom > 0 else { return value }
        return value * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        // The kernel writes the whole struct at the address passed as `rusage_info_t *`,
        // so hand it the struct's own address (not the address of a separate pointer variable).
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: rusage_info_t?.self))
        }
        return rc == 0 ? info : nil
    }

    /// Returns per-app usage. The first call only primes the counters and returns [].
    func sample() -> [AppUsage] {
        let now = ProcessInfo.processInfo.systemUptime
        let pids = ProcessIdentityResolver.allPIDs()
        var current: [pid_t: Snapshot] = [:]
        var groups: [String: AppUsage] = [:]
        var anyEnergy = false

        for pid in pids {
            guard let info = rusage(pid) else { continue }
            let cpu = nanos(fromMach: info.ri_user_time &+ info.ri_system_time)
            let snap = Snapshot(cpuNanos: cpu, energyNanojoules: info.ri_billed_energy,
                                footprint: info.ri_phys_footprint, time: now)
            current[pid] = snap
            guard let prev = previous[pid] else { continue }
            let interval = max(0.05, now - prev.time)
            let cpuDelta = Double(snap.cpuNanos &- prev.cpuNanos) / 1e9
            let cpuPercent = cpuDelta / interval / Double(CPUProbe.coreCount) * 100
            let energyDelta = Double(snap.energyNanojoules &- prev.energyNanojoules)
            let milliwatts = energyDelta / interval / 1e6
            if energyDelta > 0 { anyEnergy = true }

            let identity = resolver.identity(for: pid)
            var usage = groups[identity.groupKey] ?? AppUsage(
                id: identity.groupKey, name: identity.name, bundlePath: identity.bundlePath,
                bundleID: identity.bundleID, pid: identity.representativePID,
                cpuPercent: 0, memoryBytes: 0, energyMilliwatts: 0, processCount: 0
            )
            usage.cpuPercent += max(0, cpuPercent)
            usage.memoryBytes += snap.footprint
            usage.energyMilliwatts += max(0, milliwatts)
            usage.processCount += 1
            groups[identity.groupKey] = usage
        }

        let primed = !previous.isEmpty
        previous = current
        resolver.forget(pidsNotIn: Set(current.keys))
        if anyEnergy { hasEnergyData = true }
        return primed ? Array(groups.values) : []
    }
}
