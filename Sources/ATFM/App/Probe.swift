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
        let handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        print("corebrightness dlopen: \(handle != nil) \(handle == nil ? String(cString: dlerror()) : "")")
        if let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let obj = cls.init()
            for name in ["copyKeyboardBackgroundServiceIDs", "brightnessForKeyboard:", "setBrightness:forKeyboard:", "isKeyboardBuiltIn:", "enableAutoBrightness:forKeyboard:"] {
                print("  responds \(name): \(obj.responds(to: NSSelectorFromString(name)))")
            }
            var count: UInt32 = 0
            if let methods = class_copyMethodList(cls, &count) {
                let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(methods[$0])) }
                print("  methods: \(names.sorted().joined(separator: " | "))")
                free(methods)
            }
            typealias BoolForID = @convention(c) (AnyObject, Selector, UInt64) -> Bool
            typealias FloatForID = @convention(c) (AnyObject, Selector, UInt64) -> Float
            if let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") {
                let builtIn = unsafeBitCast(send, to: BoolForID.self)
                let bright = unsafeBitCast(send, to: FloatForID.self)
                for id: UInt64 in 0...3 {
                    print("  id \(id): builtIn \(builtIn(obj, NSSelectorFromString("isKeyboardBuiltIn:"), id)) brightness \(bright(obj, NSSelectorFromString("brightnessForKeyboard:"), id))")
                }
            }
        } else {
            print("  KeyboardBrightnessClient class not found")
        }
        do { _ = try FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash") } catch { print("trash read error: \(error.localizedDescription)") }
        let kb = KeyboardBacklight()
        print("keyboard backlight: available \(kb.isAvailable), brightness \(kb.brightness.map { String($0) } ?? "-"), set(same) ok: \(kb.setBrightness(kb.brightness ?? 0))")
        print("lock screen symbol: \(ScreenControl.canLock)")
        print("finder hidden files: \(FinderPrefs.showsHiddenFiles), desktop icons: \(FinderPrefs.desktopIconsVisible)")
        print("trash items: \(TrashInfo.itemCount.map(String.init) ?? "-"), external volumes: \(Volumes.external().map(\.lastPathComponent))")
    }
}
