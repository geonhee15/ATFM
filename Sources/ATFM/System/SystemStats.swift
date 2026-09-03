import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - CPU

struct CPUTicks {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64
    var busy: UInt64 { user + system + nice }
    var total: UInt64 { busy + idle }
}

enum CPUProbe {
    static let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    static var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// Cumulative per-core tick counters since boot.
    static func perCoreTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let rc = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard rc == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        var result: [CPUTicks] = []
        result.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            result.append(CPUTicks(
                user: UInt64(info[base + Int(CPU_STATE_USER)]),
                system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[base + Int(CPU_STATE_NICE)])
            ))
        }
        return result
    }

    /// Percent busy per core between two tick snapshots.
    static func usage(from old: [CPUTicks], to new: [CPUTicks]) -> [Double] {
        guard old.count == new.count else { return new.map { _ in 0 } }
        return zip(old, new).map { o, n in
            let total = Double(n.total &- o.total)
            let busy = Double(n.busy &- o.busy)
            return total > 0 ? min(100, max(0, busy / total * 100)) : 0
        }
    }
}

// MARK: - Memory

struct MemoryStats {
    let total: UInt64
    let appMemory: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cachedFiles: UInt64
    let swapTotal: UInt64
    let swapUsed: UInt64
    /// 1 = normal, 2 = warning, 4 = critical (kern.memorystatus_vm_pressure_level)
    let pressureLevel: Int32
    var used: UInt64 { appMemory + wired + compressed }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    var pressureLabel: String {
        switch pressureLevel {
        case 4: return "심각"
        case 2: return "주의"
        default: return "정상"
        }
    }
}

enum MemoryProbe {
    static func sample() -> MemoryStats? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let rc = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var pressure: Int32 = 1
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)

        return MemoryStats(
            total: ProcessInfo.processInfo.physicalMemory,
            appMemory: app, wired: wired, compressed: compressed, cachedFiles: cached,
            swapTotal: swap.xsu_total, swapUsed: swap.xsu_used,
            pressureLevel: pressure
        )
    }
}

// MARK: - GPU

struct GPUStats {
    let device: Double
    let renderer: Double
    let tiler: Double
}

enum GPUProbe {
    static func sample() -> GPUStats? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: GPUStats?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if result == nil,
               let props = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                let device = number(props["Device Utilization %"]) ?? number(props["GPU Activity(%)"])
                if let device {
                    result = GPUStats(
                        device: device,
                        renderer: number(props["Renderer Utilization %"]) ?? 0,
                        tiler: number(props["Tiler Utilization %"]) ?? 0
                    )
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}

// MARK: - Battery

struct BatteryStats {
    let percent: Int
    let isCharging: Bool
    let onACPower: Bool
    let minutesToEmpty: Int?
    let minutesToFull: Int?
    let temperatureC: Double?
    let cycleCount: Int?
    let healthPercent: Int?

    var statusText: String {
        if isCharging {
            if let m = minutesToFull, m > 0 { return "충전 중 · 완충까지 \(Self.format(minutes: m))" }
            return "충전 중"
        }
        if onACPower { return percent >= 100 ? "완충 · 전원 연결됨" : "전원 연결됨" }
        if let m = minutesToEmpty, m > 0 { return "배터리 · \(Self.format(minutes: m)) 남음" }
        return "배터리 사용 중"
    }

    static func format(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)시간 \(m)분" : "\(m)분"
    }
}

enum BatteryProbe {
    static func sample() -> BatteryStats? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var desc: [String: Any]?
        for source in list {
            if let d = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType {
                desc = d
                break
            }
        }
        guard let desc else { return nil }
        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = max(1, desc[kIOPSMaxCapacityKey] as? Int ?? 100)
        let percent = Int((Double(current) / Double(maxCap) * 100).rounded())
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let toEmpty = (desc[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
        let toFull = (desc[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }

        var temperature: Double?
        var cycles: Int?
        var health: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let t = property(service, "Temperature") as? Int { temperature = Double(t) / 100 }
            cycles = property(service, "CycleCount") as? Int
            if let maxCapacity = property(service, "AppleRawMaxCapacity") as? Int,
               let design = property(service, "DesignCapacity") as? Int, design > 0 {
                health = min(100, Int((Double(maxCapacity) / Double(design) * 100).rounded()))
            }
        }
        return BatteryStats(percent: min(100, percent), isCharging: charging, onACPower: onAC,
                            minutesToEmpty: toEmpty, minutesToFull: toFull,
                            temperatureC: temperature, cycleCount: cycles, healthPercent: health)
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

// MARK: - Temperature (IOHIDEventSystem sensors, private API via dlsym)

final class ThermalProbe {
    struct Reading {
        let name: String
        let celsius: Double
    }

    private typealias ClientCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloat = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    private typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?

    private let client: UnsafeMutableRawPointer?
    private let copyServices: CopyServices?
    private let copyEvent: CopyEvent?
    private let getFloat: GetFloat?
    private let copyProperty: CopyProperty?

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    var isAvailable: Bool { client != nil }

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue"),
              let propSym = dlsym(handle, "IOHIDServiceClientCopyProperty") else {
            client = nil; copyServices = nil; copyEvent = nil; getFloat = nil; copyProperty = nil
            return
        }
        let create = unsafeBitCast(createSym, to: ClientCreate.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatching.self)
        copyServices = unsafeBitCast(servicesSym, to: CopyServices.self)
        copyEvent = unsafeBitCast(eventSym, to: CopyEvent.self)
        getFloat = unsafeBitCast(floatSym, to: GetFloat.self)
        copyProperty = unsafeBitCast(propSym, to: CopyProperty.self)

        guard let c = create(nil) else { client = nil; return }
        let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        let dict = matching as CFDictionary
        setMatching(c, UnsafeRawPointer(Unmanaged.passUnretained(dict).toOpaque()))
        client = c
    }

    func readAll() -> [Reading] {
        guard let client, let copyServices, let copyEvent, let getFloat, let copyProperty,
              let servicesPtr = copyServices(client) else { return [] }
        let services = Unmanaged<CFArray>.fromOpaque(servicesPtr).takeRetainedValue() as [AnyObject]
        var readings: [Reading] = []
        let productKey = "Product" as CFString
        for service in services {
            let raw = Unmanaged.passUnretained(service).toOpaque()
            var name = "sensor"
            if let namePtr = copyProperty(raw, UnsafeRawPointer(Unmanaged.passUnretained(productKey).toOpaque())) {
                let value = Unmanaged<AnyObject>.fromOpaque(namePtr).takeRetainedValue()
                if let s = value as? String { name = s }
            }
            guard let eventPtr = copyEvent(raw, Self.temperatureEventType, 0, 0) else { continue }
            let celsius = getFloat(eventPtr, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(eventPtr).release()
            if celsius.isFinite, celsius > -40, celsius < 150 {
                readings.append(Reading(name: name, celsius: celsius))
            }
        }
        return readings
    }

    /// Averages the sensors that belong to the CPU cluster and the GPU.
    static func summarize(_ readings: [Reading]) -> (cpu: Double?, gpu: Double?) {
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let cpu = readings.filter { r in
            let n = r.name.lowercased()
            return n.contains("pacc") || n.contains("eacc") || n.contains("tdie") || n.contains("cpu") || n.contains("soc")
        }.map(\.celsius)
        let gpu = readings.filter { $0.name.lowercased().contains("gpu") }.map(\.celsius)
        return (average(cpu), average(gpu))
    }
}

// MARK: - Uptime

enum UptimeProbe {
    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
