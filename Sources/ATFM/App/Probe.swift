import AppKit

/// `ATFM --probe` prints what the system/network samplers can see on this Mac. Debug aid only.
enum Probe {
    @MainActor
    static func run() {
        print("chip: \(CPUProbe.chipName), cores: \(CPUProbe.coreCount)")
        let thermal = ThermalProbe()
        print("thermal available: \(thermal.isAvailable)")
        let readings = thermal.readAll()
        for r in readings.prefix(40) { print(String(format: "  %-32@ %.1f °C", r.name as NSString, r.celsius)) }
        let summary = ThermalProbe.summarize(readings)
        print("  cpu avg: \(summary.cpu.map { String(format: "%.1f", $0) } ?? "-"), gpu avg: \(summary.gpu.map { String(format: "%.1f", $0) } ?? "-")")
        if let gpu = GPUProbe.sample() { print("gpu: device \(gpu.device)% renderer \(gpu.renderer)% tiler \(gpu.tiler)%") } else { print("gpu: unavailable") }
        if let m = MemoryProbe.sample() {
            print("memory: used \(Format.memory(m.used)) / \(Format.memory(m.total)) app \(Format.memory(m.appMemory)) wired \(Format.memory(m.wired)) compressed \(Format.memory(m.compressed)) swap \(Format.memory(m.swapUsed)) pressure \(m.pressureLevel)")
        }
        if let b = BatteryProbe.sample() {
            print("battery: \(b.percent)% \(b.statusText) temp \(b.temperatureC ?? -1) cycles \(b.cycleCount ?? -1) health \(b.healthPercent ?? -1)")
        } else { print("battery: none") }

        print("step: resolver"); fflush(stdout)
        let resolver = ProcessIdentityResolver()
        print("step: sampler"); fflush(stdout)
        let sampler = ProcessSampler(resolver: resolver)
        print("step: ticks"); fflush(stdout)
        let ticks0 = CPUProbe.perCoreTicks()
        print("step: pids \(ProcessIdentityResolver.allPIDs().count)"); fflush(stdout)
        print("step: identity self = \(resolver.identity(for: getpid()).name)"); fflush(stdout)
        print("step: sample1"); fflush(stdout)
        _ = sampler.sample()
        print("step: sleep"); fflush(stdout)
        Thread.sleep(forTimeInterval: 1.5)
        let usage = CPUProbe.usage(from: ticks0, to: CPUProbe.perCoreTicks())
        print("cpu total: \(String(format: "%.1f", usage.reduce(0, +) / Double(max(1, usage.count))))% per-core: \(usage.map { Int($0) })")
        let apps = sampler.sample().sorted { $0.cpuPercent > $1.cpuPercent }
        print("apps (\(apps.count) groups, energy data: \(sampler.hasEnergyData)):")
        for a in apps.prefix(8) {
            print(String(format: "  %-28@ cpu %5.1f%%  mem %10@  energy %8@  procs %d  app=%@", a.name as NSString, a.cpuPercent, Format.memory(a.memoryBytes) as NSString, Format.milliwatts(a.energyMilliwatts) as NSString, a.processCount, (a.bundlePath != nil) ? "yes" : "no"))
        }
        print("uptime: \(UptimeProbe.format(UptimeProbe.uptime))")
    }
}
