import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import Observation
import os

/// Reads the system output mix through a Core Audio process tap (macOS 14.2+) and reduces it to
/// five band levels for the mini player's visualizer. Needs the "system audio recording" grant;
/// until real signal shows up the view falls back to its decorative animation.
@MainActor
@Observable
final class AudioLevelMonitor {
    enum Status: Equatable {
        case idle, running
        case unavailable(String)
    }

    private(set) var status: Status = .idle
    private(set) var isRunning = false
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: BandAnalyzer.bandCount)
    /// True once non-silent audio has arrived (so silence vs. missing permission can be told apart).
    private(set) var signalSeen = false

    @ObservationIgnored private var tapID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var ioProcID: AudioDeviceIOProcID?
    @ObservationIgnored private let analyzer = BandAnalyzer()
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard !isRunning else { return }
        guard #available(macOS 14.2, *) else {
            status = .unavailable("macOS 14.2 이상에서만 가능해요")
            return
        }
        do {
            try createTap()
            isRunning = true
            status = .running
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Self.note("start ok tap=\(tapID) aggregate=\(aggregateID)")
        } catch {
            status = .unavailable(error.localizedDescription)
            Self.note("start failed: \(error.localizedDescription)")
            teardown()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        teardown()
        if isRunning { Self.note("stop signalSeen=\(signalSeen)") }
        isRunning = false
        levels = Array(repeating: 0, count: BandAnalyzer.bandCount)
        signalSeen = false
        if status == .running { status = .idle }
    }

    private func publish() {
        let current = analyzer.snapshot()
        levels = current.levels.map { CGFloat($0) }
        if current.signalSeen, !signalSeen {
            signalSeen = true
            Self.note("signal seen levels=\(current.levels.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        }
    }

    // MARK: Core Audio plumbing

    private struct TapError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @available(macOS 14.2, *)
    private func createTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "ATFM 비주얼라이저"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.isMixdown = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw TapError(message: "오디오 탭을 만들지 못했어요 (\(status))") }
        tapID = tap

        // Tap stream format (sample rate / channel layout of the output mix).
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw TapError(message: "탭 포맷을 읽지 못했어요 (\(status))") }
        analyzer.configure(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame),
                           interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)

        // Default output device UID → aggregate device that hosts the tap.
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &outputDevice)
        guard status == noErr, outputDevice != kAudioObjectUnknown else { throw TapError(message: "출력 장치를 찾지 못했어요") }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(outputDevice, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw TapError(message: "출력 장치 UID를 읽지 못했어요") }

        let aggregate: [String: Any] = [
            "name": "ATFM Visualizer Tap",
            "uid": "com.geonhee.atfm.visualizer.\(UUID().uuidString)",
            "master": uid as String,
            "private": true,
            "stacked": false,
            "tapautostart": true,
            "subdevices": [["uid": uid as String]],
            "taps": [["uid": description.uuid.uuidString, "drift": true]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr, aggregateDevice != kAudioObjectUnknown else { throw TapError(message: "집계 장치를 만들지 못했어요 (\(status))") }
        aggregateID = aggregateDevice

        let analyzer = self.analyzer
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, _, _, _ in
            analyzer.process(inputData)
        }
        guard status == noErr, let procID else { throw TapError(message: "오디오 콜백을 만들지 못했어요 (\(status))") }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError(message: "오디오 장치를 시작하지 못했어요 (\(status))") }
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
        analyzer.reset()
    }

    func debugNote(_ prefix: String) {
        Self.note("\(prefix) status=\(status) signal=\(signalSeen) levels=\(levels.map { String(format: "%.2f", Double($0)) }.joined(separator: " "))")
    }

    /// Small diagnostics trail next to the app data (see also screen-access.txt).
    private static func note(_ text: String) {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = base.appendingPathComponent("ATFM/audio-tap.txt")
        let line = "\(Date()) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Runs on the audio thread: mixes to mono, 1024-point DFT, five log-spaced bands, smoothed.
final class BandAnalyzer: @unchecked Sendable {
    static let bandCount = 5
    private static let n = 1024
    private static let bandEdgesHz: [Float] = [40, 160, 450, 1300, 4000, 12000]

    private let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(BandAnalyzer.n), .FORWARD)
    private var window = [Float](repeating: 0, count: BandAnalyzer.n)
    private var ring = [Float](repeating: 0, count: BandAnalyzer.n)
    private var ringIndex = 0
    private var ordered = [Float](repeating: 0, count: BandAnalyzer.n)
    private var inReal = [Float](repeating: 0, count: BandAnalyzer.n / 2)
    private var inImag = [Float](repeating: 0, count: BandAnalyzer.n / 2)
    private var outReal = [Float](repeating: 0, count: BandAnalyzer.n / 2)
    private var outImag = [Float](repeating: 0, count: BandAnalyzer.n / 2)
    private var magnitudes = [Float](repeating: 0, count: BandAnalyzer.n / 2)
    private var smoothed = [Float](repeating: 0, count: BandAnalyzer.bandCount)
    private var signal = false
    private var lock = os_unfair_lock()
    private var sampleRate: Float = 48000
    private var channels = 2
    private var interleaved = false

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.n), Int32(vDSP_HANN_NORM))
    }

    func configure(sampleRate: Double, channels: Int, interleaved: Bool) {
        os_unfair_lock_lock(&lock)
        self.sampleRate = Float(sampleRate)
        self.channels = max(1, channels)
        self.interleaved = interleaved
        os_unfair_lock_unlock(&lock)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        smoothed = [Float](repeating: 0, count: Self.bandCount)
        ring = [Float](repeating: 0, count: Self.n)
        ringIndex = 0
        signal = false
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> (levels: [Float], signalSeen: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (smoothed, signal)
    }

    /// Called from the Core Audio IO thread with the tap's input buffers.
    func process(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let base = first.mData else { return }
        os_unfair_lock_lock(&lock)
        let channels = self.channels
        let interleaved = self.interleaved
        var peak: Float = 0
        if interleaved {
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let samples = base.assumingMemoryBound(to: Float.self)
            let frames = count / channels
            for frame in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += samples[frame * channels + ch] }
                let mono = sum / Float(channels)
                ring[ringIndex] = mono
                ringIndex = (ringIndex + 1) % Self.n
                peak = max(peak, abs(mono))
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let pointers = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            for frame in 0..<frames {
                var sum: Float = 0
                for p in pointers { sum += p[frame] }
                let mono = sum / Float(max(1, pointers.count))
                ring[ringIndex] = mono
                ringIndex = (ringIndex + 1) % Self.n
                peak = max(peak, abs(mono))
            }
        }
        if peak > 0.001 { signal = true }
        analyzeLocked()
        os_unfair_lock_unlock(&lock)
    }

    private func analyzeLocked() {
        guard let setup else { return }
        // Oldest → newest, windowed.
        for i in 0..<Self.n { ordered[i] = ring[(ringIndex + i) % Self.n] * window[i] }
        // Split even/odd for the real-to-complex DFT.
        for i in 0..<(Self.n / 2) {
            inReal[i] = ordered[2 * i]
            inImag[i] = ordered[2 * i + 1]
        }
        vDSP_DFT_Execute(setup, inReal, inImag, &outReal, &outImag)
        var split = DSPSplitComplex(realp: &outReal, imagp: &outImag)
        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(Self.n / 2))
        var scale = 2 / Float(Self.n)          // unnormalized DFT → a full-scale sine reads ≈ 1.0 (0 dBFS)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(Self.n / 2))
        let binHz = sampleRate / Float(Self.n)
        for band in 0..<Self.bandCount {
            let low = max(1, Int(Self.bandEdgesHz[band] / binHz))
            let high = min(Self.n / 2 - 1, max(low, Int(Self.bandEdgesHz[band + 1] / binHz)))
            var sum: Float = 0
            for bin in low...high { sum += magnitudes[bin] }
            let mean = sum / Float(high - low + 1)
            let db = 20 * log10(max(mean, 1e-6))
            let level = min(1, max(0, (db + 62) / 52))        // -62 dBFS → 0, -10 dBFS → 1
            let previous = smoothed[band]
            smoothed[band] = previous + (level - previous) * (level > previous ? 0.55 : 0.18)
        }
    }
}
