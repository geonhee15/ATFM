import AudioToolbox
import CoreAudio
import Foundation
import os

/// Per-app volume: tap one process (muted at the speakers while tapped) and play its audio back
/// through the default output device at the chosen gain. Removing the route restores the normal path.
final class ProcessTapRoute: @unchecked Sendable {
    let key: String
    let objectIDs: [AudioObjectID]
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var gainLock = os_unfair_lock()
    private var gainValue: Float

    struct RouteError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var gain: Float {
        get { os_unfair_lock_lock(&gainLock); defer { os_unfair_lock_unlock(&gainLock) }; return gainValue }
        set { os_unfair_lock_lock(&gainLock); gainValue = newValue; os_unfair_lock_unlock(&gainLock) }
    }

    @available(macOS 14.2, *)
    init(key: String, objectIDs: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.key = key
        self.objectIDs = objectIDs
        gainValue = gain
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        description.uuid = UUID()
        description.name = "ATFM 앱 볼륨 \(key)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw RouteError(message: "오디오 탭 생성 실패 (\(status))") }
        tapID = tap

        let aggregate: [String: Any] = [
            "name": "ATFM App Volume \(key)",
            "uid": "com.geonhee.atfm.appvolume.\(UUID().uuidString)",
            "master": outputUID,
            "private": true,
            "stacked": false,
            "tapautostart": true,
            "subdevices": [["uid": outputUID]],
            "taps": [["uid": description.uuid.uuidString, "drift": true]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr, aggregateDevice != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RouteError(message: "집계 장치 생성 실패 (\(status))")
        }
        aggregateID = aggregateDevice

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [self] _, inputData, _, outputData, _ in
            Self.render(from: inputData, to: outputData, gain: self.gain)
        }
        guard status == noErr, let procID else {
            teardown()
            throw RouteError(message: "오디오 콜백 생성 실패 (\(status))")
        }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            teardown()
            throw RouteError(message: "오디오 장치 시작 실패 (\(status))")
        }
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = kAudioObjectUnknown
        }
    }

    /// Copies tap channels to the device's output channels (cycling when counts differ), scaled by gain.
    private static func render(from input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        // Input channels as (base pointer, stride, frames).
        var sources: [(UnsafeMutablePointer<Float>, Int, Int)] = []
        sources.reserveCapacity(4)
        for buffer in inList {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let base = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels { sources.append((base + channel, channels, frames)) }
        }
        var outputChannel = 0
        for buffer in outList {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let base = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                if sources.isEmpty || gain <= 0 {
                    for frame in 0..<frames { base[frame * channels + channel] = 0 }
                } else {
                    let source = sources[outputChannel % sources.count]
                    let count = min(frames, source.2)
                    for frame in 0..<count { base[frame * channels + channel] = source.0[frame * source.1] * gain }
                    if count < frames { for frame in count..<frames { base[frame * channels + channel] = 0 } }
                }
                outputChannel += 1
            }
        }
    }
}
