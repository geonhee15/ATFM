import AppKit
import Observation

enum AppSortMode: String, CaseIterable, Identifiable {
    case cpu, memory, energy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "메모리"
        case .energy: return "에너지"
        }
    }
}

/// Live system statistics for the 시스템 tab. Sampling only runs while the tab is visible.
@MainActor
@Observable
final class SystemMonitor {
    static let historyLength = 60

    var cpuPercent: Double = 0
    var perCore: [Double] = []
    var cpuHistory: [Double] = []
    var gpu: GPUStats?
    var gpuHistory: [Double] = []
    var memory: MemoryStats?
    var memoryHistory: [Double] = []
    var battery: BatteryStats?
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var uptime: TimeInterval = UptimeProbe.uptime
    var apps: [AppUsage] = []
    var sortMode: AppSortMode = .cpu
    var hasEnergyData = false
    var isActive = false
    let chipName = CPUProbe.chipName
    let performanceCores: Int
    let efficiencyCores: Int

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: [CPUTicks] = []
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private let processSampler: ProcessSampler
    @ObservationIgnored private let thermal = ThermalProbe()

    init(resolver: ProcessIdentityResolver) {
        processSampler = ProcessSampler(resolver: resolver)
        performanceCores = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? CPUProbe.coreCount
        efficiencyCores = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    }

    var sortedApps: [AppUsage] {
        switch sortMode {
        case .cpu: return apps.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return apps.sorted { $0.memoryBytes > $1.memoryBytes }
        case .energy: return apps.sorted { $0.energyMilliwatts > $1.energyMilliwatts }
        }
    }

    func setActive(_ active: Bool) {
        if active { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        isActive = true
        lastTicks = CPUProbe.perCoreTicks()
        _ = processSampler.sample()   // prime counters
        sampleSlow()
        sampleFast()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isActive = false
    }

    private func tick() {
        tickCount += 1
        sampleFast()
        if tickCount % 2 == 0 { sampleApps() }
        if tickCount % 5 == 0 { sampleSlow() }
    }

    private func sampleFast() {
        let ticks = CPUProbe.perCoreTicks()
        if !lastTicks.isEmpty {
            perCore = CPUProbe.usage(from: lastTicks, to: ticks)
            let avg = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
            cpuPercent = avg
            Self.push(&cpuHistory, avg)
        }
        lastTicks = ticks

        if let g = GPUProbe.sample() {
            gpu = g
            Self.push(&gpuHistory, g.device)
        }
        if let m = MemoryProbe.sample() {
            memory = m
            Self.push(&memoryHistory, m.usedFraction * 100)
        }
        uptime = UptimeProbe.uptime
    }

    private func sampleApps() {
        let usage = processSampler.sample()
        if !usage.isEmpty { apps = usage }
        // ri_billed_energy deltas are not meaningful per app on this hardware (a few mW for busy apps),
        // so the energy sort stays hidden until a better source is wired in.
        hasEnergyData = false
    }

    private func sampleSlow() {
        battery = BatteryProbe.sample()
        if thermal.isAvailable {
            let summary = ThermalProbe.summarize(thermal.readAll())
            cpuTemperature = summary.cpu
            gpuTemperature = summary.gpu
        }
    }

    private static func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
