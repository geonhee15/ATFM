import AVFoundation
import Foundation

/// Double-clap detector ported from Security-Protocol-1's `AudioClapDetector` (audio-only mode).
/// Works on 16 ms blocks: an onset must be loud (absolute + relative to an adaptive noise floor),
/// broadband (high adjacent-sample difference energy) and short (tail decays below 35% of the core);
/// two onsets 0.12–1.0 s apart form a candidate that is confirmed only when nothing else fires
/// 0.6 s before the first and 0.5 s after the second (typing bursts fail that isolation rule).
final class ClapDetector {
    struct Config {
        var peakOverFloor = 12.0
        var absMinPeak = 0.10
        var isolationSec = 0.5
        var preQuietSec = 0.6
        var hfRatioMin = 0.20
        var decayBlocks = 9
        var decayRatio = 0.35
        var refractorySec = 0.07
        var gapMin = 0.12
        var gapMax = 1.0
    }

    static let blockDuration = 0.016

    var config: Config
    private let lock = NSLock()
    private(set) var floor = 3e-3
    private(set) var lastPeak = 0.0
    private(set) var lastOnset = -10.0
    private var pending: (time: Double, rms: Double)?
    private var tail: [Double] = []
    private var onsets: [Double] = []
    private var candidate: (Double, Double)?

    init(config: Config = Config()) {
        self.config = config
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
        tail = []
        onsets = []
        candidate = nil
        lastOnset = -10
    }

    /// Feed one block's features (peak, RMS, broadband ratio) stamped with its time.
    func process(now: Double, peak: Double, rms: Double, hf: Double) {
        lock.lock(); defer { lock.unlock() }
        lastPeak = peak
        if let pendingOnset = pending {
            tail.append(rms)
            if tail.count >= config.decayBlocks {
                // The attack can spread over a few blocks: take the loudest of onset+2 as the core and
                // require the later tail (~80 ms on) to fall well below it — sustained sounds don't.
                let core = ([pendingOnset.rms] + tail.prefix(2)).max() ?? pendingOnset.rms
                let late = tail.dropFirst(4)
                let tailRMS = late.isEmpty ? 0 : late.reduce(0, +) / Double(late.count)
                pending = nil
                tail = []
                if tailRMS < core * config.decayRatio {
                    registerOnset(pendingOnset.time)
                }
            }
            return
        }
        if peak > config.absMinPeak,
           peak > floor * config.peakOverFloor,
           hf > config.hfRatioMin,
           now - lastOnset > config.refractorySec {
            pending = (now, rms)
            tail = []
        } else {
            // Only quiet blocks feed the floor so a clap can't raise it against itself.
            floor = max(1e-4, floor * 0.98 + rms * 0.02)
        }
    }

    private func registerOnset(_ t: Double) {
        lastOnset = t
        if candidate != nil {
            candidate = nil   // a third impulse before confirmation = typing / burst → cancel
        }
        let previous = onsets.filter { t - $0 > 0 && t - $0 <= config.gapMax + config.preQuietSec }
        if let t1 = previous.last {
            let gap = t - t1
            if gap >= config.gapMin, gap <= config.gapMax {
                let earlier = previous.dropLast()
                if earlier.contains(where: { t1 - $0 > 0 && t1 - $0 < config.preQuietSec }) {
                    append(onset: t)
                    return
                }
                candidate = (t1, t)
            }
        }
        append(onset: t)
    }

    private func append(onset: Double) {
        onsets.append(onset)
        if onsets.count > 8 { onsets.removeFirst(onsets.count - 8) }
    }

    /// Returns the (first, second) clap times once a candidate has survived the isolation window.
    func pollDouble(now: Double) -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let (t1, t2) = candidate else { return nil }
        if pending != nil || now - t2 < config.isolationSec { return nil }
        candidate = nil
        onsets = []
        return (t1, t2)
    }

    /// Was there an audio onset within `tolerance` seconds of `time`? (vision double-clap confirmation)
    func onsetNear(_ time: Double, tolerance: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if lastOnset > 0, abs(lastOnset - time) <= tolerance { return true }
        return onsets.contains { abs($0 - time) <= tolerance }
    }

    /// True while the first clap of a pair is waiting for its partner (for the "한 번 더" hint).
    func awaitingSecondClap(now: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard candidate == nil, let last = onsets.last else { return false }
        return now - last <= config.gapMax
    }

    // MARK: Feature extraction

    /// Splits a Float32 mono signal into 16 ms blocks and returns (peak, rms, hf) per block.
    static func features(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> [(peak: Double, rms: Double, hf: Double)] {
        let blockSize = max(64, Int(sampleRate * blockDuration))
        var result: [(Double, Double, Double)] = []
        var start = 0
        while start + blockSize <= count {
            var peak: Float = 0, energy: Float = 0, diffEnergy: Float = 0
            var previous = samples[start]
            for i in start..<(start + blockSize) {
                let x = samples[i]
                let a = abs(x)
                if a > peak { peak = a }
                energy += x * x
                let d = x - previous
                diffEnergy += d * d
                previous = x
            }
            let rms = Double(sqrt(energy / Float(blockSize))) + 1e-9
            let hf = Double(diffEnergy / (energy + 1e-12))
            result.append((Double(peak), rms, hf))
            start += blockSize
        }
        return result
    }
}

/// Runs the microphone through AVAudioEngine and feeds the detector.
final class ClapAudioInput {
    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private(set) var isRunning = false
    var onLevel: ((Double) -> Void)?

    let detector: ClapDetector

    init(detector: ClapDetector) {
        self.detector = detector
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "ATFM.Clap", code: 1, userInfo: [NSLocalizedDescriptionKey: "입력 장치를 찾지 못했어요"])
        }
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            let blocks = ClapDetector.features(samples: channel, count: frames, sampleRate: sampleRate)
            let end = CACurrentMediaTime()
            let total = Double(frames) / sampleRate
            var maxPeak = 0.0
            for (index, block) in blocks.enumerated() {
                let time = end - total + Double(index + 1) * ClapDetector.blockDuration
                self.detector.process(now: time, peak: block.peak, rms: block.rms, hf: block.hf)
                maxPeak = max(maxPeak, block.peak)
            }
            self.onLevel?(maxPeak)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            // Device changed (AirPods, external mic…): restart the tap on the new format.
            self.stop()
            try? self.start()
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }
}
