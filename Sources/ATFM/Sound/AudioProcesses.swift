import CoreAudio
import Foundation

/// A process Core Audio knows about (macOS 14.2+ process objects).
struct AudioProcess: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

enum AudioProcesses {
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func list() -> [AudioProcess] {
        var listAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0 else { return nil }
            var bundle: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            var bundleAddress = address(kAudioProcessPropertyBundleID)
            let gotBundle = withUnsafeMutablePointer(to: &bundle) {
                AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, $0) == noErr
            }
            let bundleID: String? = gotBundle ? (bundle as String) : nil
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = address(kAudioProcessPropertyIsRunningOutput)
            _ = AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &runningSize, &running)
            return AudioProcess(objectID: id, pid: pid, bundleID: (bundleID?.isEmpty ?? true) ? nil : bundleID, isRunningOutput: running != 0)
        }
    }

    static func defaultOutputDevice() -> (id: AudioObjectID, uid: String, name: String)? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = address(kAudioDevicePropertyDeviceUID)
        guard withUnsafeMutablePointer(to: &uid, { AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &size, $0) }) == noErr else { return nil }
        var name: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = address(kAudioObjectPropertyName)
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &size, $0) }
        return (id, uid as String, name as String)
    }
}
