import CoreAudio
import Foundation
import Observation

/// System output volume / mute through Core Audio, kept in sync with the keyboard volume keys.
@MainActor
@Observable
final class SystemVolume {
    private(set) var volume: Double = 0        // 0…1
    private(set) var isMuted = false
    private(set) var isAvailable = false

    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var listenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var watchedAddresses: [AudioObjectPropertyAddress] = []

    /// 'vmvc' — the virtual main/master output volume (the AudioToolbox constant is not exposed to Swift here).
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)
    private static let volumeAddress = AudioObjectPropertyAddress(mSelector: virtualMainVolume,
                                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                                  mElement: kAudioObjectPropertyElementMain)
    private static let muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                                mScope: kAudioObjectPropertyScopeOutput,
                                                                mElement: kAudioObjectPropertyElementMain)
    private static let defaultDeviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                                         mElement: kAudioObjectPropertyElementMain)

    init() {
        attach()
        var address = Self.defaultDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.attach() } }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    /// (Re)bind to the current default output device and start listening for volume / mute changes.
    private func attach() {
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.defaultDeviceAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { isAvailable = false; return }
        device = id
        var volumeAddress = Self.volumeAddress
        isAvailable = AudioObjectHasProperty(device, &volumeAddress)
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        listenerBlock = block
        for var candidate in [Self.volumeAddress, Self.muteAddress] where AudioObjectHasProperty(device, &candidate) {
            AudioObjectAddPropertyListenerBlock(device, &candidate, DispatchQueue.main, block)
            watchedAddresses.append(candidate)
        }
    }

    private func detach() {
        guard let block = listenerBlock, device != kAudioObjectUnknown else { return }
        for var address in watchedAddresses { AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block) }
        watchedAddresses = []
        listenerBlock = nil
    }

    private func refresh() {
        guard device != kAudioObjectUnknown else { return }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
            volume = Double(max(0, min(1, value)))
        }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = Self.muteAddress
        if AudioObjectHasProperty(device, &muteAddress), AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr {
            isMuted = muted != 0
        }
    }

    func setVolume(_ newValue: Double) {
        guard device != kAudioObjectUnknown else { return }
        var value = Float32(max(0, min(1, newValue)))
        var address = Self.volumeAddress
        if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
            volume = Double(value)
            if isMuted, value > 0 { setMuted(false) }
        }
    }

    func setMuted(_ muted: Bool) {
        guard device != kAudioObjectUnknown else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.muteAddress
        guard AudioObjectHasProperty(device, &address) else { return }
        if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
            isMuted = muted
        }
    }

    func toggleMute() { setMuted(!isMuted) }

    var symbol: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
