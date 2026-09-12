import AppKit
import CoreAudio
import Observation

struct SoundApp: Identifiable, Equatable {
    let id: String             // resolver group key (helpers fold into their app)
    let objectIDs: [AudioObjectID]
    let storageKey: String     // bundle ID or path, for remembering the level
    let name: String
    let bundlePath: String?
    let isPlaying: Bool
    var volume: Double         // 0…1, 1 = untouched
}

/// 사운드 tab: per-app volume (process taps), left/right output channel levels, master volume.
@MainActor
@Observable
final class SoundPanel {
    private(set) var apps: [SoundApp] = []
    private(set) var deviceName = ""
    private(set) var left: Double = 1
    private(set) var right: Double = 1
    private(set) var channelsAvailable = false
    private(set) var lastError: String?
    private(set) var isActive = false
    private(set) var supported: Bool

    /// Remembered per bundle ID so an app keeps its level across launches.
    @ObservationIgnored private var storedVolumes: [String: Double]
    @ObservationIgnored private var routes: [String: ProcessTapRoute] = [:]
    @ObservationIgnored private let resolver = ProcessIdentityResolver()
    @ObservationIgnored private var panAvailable = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var outputUID = ""
    @ObservationIgnored private var channelListener: AudioObjectPropertyListenerBlock?
    private static let volumesKey = "appVolumes"

    init() {
        if #available(macOS 14.2, *) { supported = true } else { supported = false }
        storedVolumes = UserDefaults.standard.dictionary(forKey: Self.volumesKey) as? [String: Double] ?? [:]
        bindDevice()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.outputDeviceChanged() } }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        refresh()
    }

    // MARK: Activity (poll only while the tab is visible)

    func setActive(_ active: Bool) {
        isActive = active
        timer?.invalidate()
        timer = nil
        guard active else { return }
        refresh()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Apps

    func refresh() {
        let processes = AudioProcesses.list()
        let me = ProcessInfo.processInfo.processIdentifier
        // Fold helper processes (Chrome renderers, Spotify helpers…) into the app that owns them.
        var groups: [String: (identity: ProcessIdentityResolver.Identity, objectIDs: [AudioObjectID], playing: Bool)] = [:]
        var order: [String] = []
        for process in processes where process.pid != me {
            let identity = resolver.identity(for: process.pid)
            if identity.bundleID == Bundle.main.bundleIdentifier { continue }
            if groups[identity.groupKey] == nil {
                groups[identity.groupKey] = (identity, [], false)
                order.append(identity.groupKey)
            }
            groups[identity.groupKey]!.objectIDs.append(process.objectID)
            if process.isRunningOutput { groups[identity.groupKey]!.playing = true }
        }
        var list: [SoundApp] = []
        for key in order {
            guard let group = groups[key] else { continue }
            let storageKey = group.identity.bundleID ?? group.identity.bundlePath ?? key
            let stored = storedVolumes[storageKey]
            let adjusted = routes[key] != nil || (stored ?? 1) < 1
            guard group.playing || adjusted else { continue }
            let volume = routes[key].map { Double($0.gain) } ?? stored ?? 1
            let app = SoundApp(id: key, objectIDs: group.objectIDs, storageKey: storageKey, name: group.identity.name,
                               bundlePath: group.identity.bundlePath, isPlaying: group.playing, volume: volume)
            list.append(app)
            if let route = routes[key], Set(route.objectIDs) != Set(group.objectIDs) {
                // New helper processes appeared (or old ones left): rebuild the tap so it covers all of them.
                route.stop()
                routes[key] = nil
                apply(volume: Double(route.gain), to: app)
            } else if routes[key] == nil, let stored, stored < 1, group.playing {
                apply(volume: stored, to: app)     // remembered level for an app that started playing again
            }
        }
        for key in routes.keys where groups[key] == nil {
            routes[key]?.stop()
            routes[key] = nil
        }
        apps = list.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        readChannels()
    }

    func setVolume(_ value: Double, for app: SoundApp) {
        let clamped = max(0, min(1, value))
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index].volume = clamped }
        if clamped >= 0.999 { storedVolumes[app.storageKey] = nil } else { storedVolumes[app.storageKey] = clamped }
        UserDefaults.standard.set(storedVolumes, forKey: Self.volumesKey)
        apply(volume: clamped, to: app)
    }

    private func apply(volume: Double, to app: SoundApp) {
        if volume >= 0.999 {
            routes[app.id]?.stop()
            routes[app.id] = nil
            return
        }
        if let route = routes[app.id] {
            route.gain = Float(volume)
            return
        }
        guard #available(macOS 14.2, *) else { lastError = "앱별 볼륨은 macOS 14.2 이상에서만 가능해요"; return }
        guard !outputUID.isEmpty else { lastError = "출력 장치를 찾지 못했어요"; return }
        do {
            routes[app.id] = try ProcessTapRoute(key: app.id, objectIDs: app.objectIDs, outputUID: outputUID, gain: Float(volume))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resetAllVolumes() {
        for route in routes.values { route.stop() }
        routes = [:]
        storedVolumes = [:]
        UserDefaults.standard.set(storedVolumes, forKey: Self.volumesKey)
        for index in apps.indices { apps[index].volume = 1 }
    }

    func stopAll() {
        for route in routes.values { route.stop() }
        routes = [:]
    }

    // MARK: Output device + left/right

    private func bindDevice() {
        guard let output = AudioProcesses.defaultOutputDevice() else { device = kAudioObjectUnknown; outputUID = ""; return }
        device = output.id
        outputUID = output.uid
        deviceName = output.name
        var leftAddress = channelAddress(1), rightAddress = channelAddress(2)
        let perChannel = AudioObjectHasProperty(device, &leftAddress) && AudioObjectHasProperty(device, &rightAddress)
        var panAddress = Self.panAddress, mainAddress = Self.mainVolumeAddress
        panAvailable = !perChannel && AudioObjectHasProperty(device, &panAddress) && AudioObjectHasProperty(device, &mainAddress)
        channelsAvailable = perChannel || panAvailable
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.readChannels() } }
        }
        channelListener = block
        if perChannel {
            AudioObjectAddPropertyListenerBlock(device, &leftAddress, DispatchQueue.main, block)
            AudioObjectAddPropertyListenerBlock(device, &rightAddress, DispatchQueue.main, block)
        } else if panAvailable {
            AudioObjectAddPropertyListenerBlock(device, &panAddress, DispatchQueue.main, block)
            AudioObjectAddPropertyListenerBlock(device, &mainAddress, DispatchQueue.main, block)
        }
        readChannels()
    }

    private static let panAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStereoPan,
                                                               mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static let mainVolumeAddress = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(0x766D_7663),   // 'vmvc'
                                                                      mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private func readFloat(_ address: AudioObjectPropertyAddress) -> Double? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = address
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? Double(value) : nil
    }

    private func writeFloat(_ address: AudioObjectPropertyAddress, _ newValue: Double) -> Bool {
        var value = Float32(max(0, min(1, newValue)))
        var address = address
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private func outputDeviceChanged() {
        // Routes are bound to the old device: rebuild them on the new one (refresh re-applies stored levels).
        for (_, route) in routes { route.stop() }
        routes = [:]
        bindDevice()
        refresh()
    }

    private func channelAddress(_ channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: channel)
    }

    private func readChannels() {
        guard channelsAvailable, device != kAudioObjectUnknown else { return }
        if panAvailable {
            // Pan 0…1 (0.5 = centre) + main volume → what each side actually gets.
            guard let pan = readFloat(Self.panAddress), let main = readFloat(Self.mainVolumeAddress) else { return }
            left = main * min(1, 2 * (1 - pan))
            right = main * min(1, 2 * pan)
        } else {
            if let value = readFloat(channelAddress(1)) { left = value }
            if let value = readFloat(channelAddress(2)) { right = value }
        }
    }

    func setChannel(left newLeft: Double? = nil, right newRight: Double? = nil) {
        guard channelsAvailable, device != kAudioObjectUnknown else { return }
        let targetLeft = max(0, min(1, newLeft ?? left))
        let targetRight = max(0, min(1, newRight ?? right))
        if panAvailable {
            // Express (L, R) as main = louder side, pan = the quieter side's ratio.
            let main = max(targetLeft, targetRight)
            let pan: Double
            if main <= 0 { pan = 0.5 } else if targetLeft >= targetRight { pan = 0.5 * (targetRight / main) } else { pan = 1 - 0.5 * (targetLeft / main) }
            _ = writeFloat(Self.mainVolumeAddress, main)
            _ = writeFloat(Self.panAddress, pan)
            readChannels()
        } else {
            if newLeft != nil, writeFloat(channelAddress(1), targetLeft) { left = targetLeft }
            if newRight != nil, writeFloat(channelAddress(2), targetRight) { right = targetRight }
        }
    }

    func centerChannels() {
        let level = max(left, right)
        setChannel(left: level, right: level)
    }
}
