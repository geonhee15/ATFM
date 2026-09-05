import AVFoundation
import Foundation
import Vision

/// A hand as SP1's ClapDetector sees it: normalized landmark positions for wrist + finger MCPs.
struct HandLandmarks {
    let wrist: CGPoint
    let indexMCP: CGPoint
    let middleMCP: CGPoint
    let ringMCP: CGPoint
    let littleMCP: CGPoint

    /// Mean of wrist + 4 MCPs (SP1 `_palm`).
    var palm: CGPoint {
        let points = [wrist, indexMCP, middleMCP, ringMCP, littleMCP]
        return CGPoint(x: points.map(\.x).reduce(0, +) / 5, y: points.map(\.y).reduce(0, +) / 5)
    }

    /// Wrist → middle MCP distance (SP1 `_size`).
    var size: CGFloat { max(0.001, hypot(wrist.x - middleMCP.x, wrist.y - middleMCP.y)) }
}

/// Port of Security-Protocol-1's vision `ClapDetector`: two-hand contact / merge inference for a
/// vision double clap, plus the "typing posture" gate used to veto audio double claps.
final class VisionClapDetector {
    private let lock = NSLock()
    // Same constants as SP1.
    private let contactR = 0.65, nearR = 1.5, rearmR = 0.8, minApproach = 2.2
    private let maxContactSec = 0.5, gapMin = 0.08, gapMax = 1.2
    private let apartR = 1.3, typingFrac = 0.85

    private var history: [(time: Double, state: String)] = []   // none / one / apart / close
    private var armed = true
    private var hadTwo = false
    private var lastMid: CGPoint?
    private var lastDist: Double?
    private var approach = 0.0
    private var prevDist: Double?
    private var prevTime: Double?
    private var lastClapAt = -10.0
    private var hitAt = -10.0
    private var hitDirect = false
    private(set) var claps = 0
    private(set) var handsSeenAt = -1e9
    private(set) var lastHandCount = 0

    var debugState: String {
        lock.lock(); defer { lock.unlock() }
        return String(format: "armed=%@ dist=%.2f approach=%.1f hadTwo=%@", armed ? "y" : "n", lastDist ?? -1, approach, hadTwo ? "y" : "n")
    }

    private func hit(now: Double, direct: Bool) -> Bool {
        hitAt = now
        hitDirect = direct
        armed = false
        let gap = now - lastClapAt
        lastClapAt = now
        if claps == 1, gap >= gapMin, gap <= gapMax {
            claps = 0
            return true
        }
        claps = 1
        return false
    }

    /// Was the camera seeing two hands far apart for almost the whole window? (keyboard posture)
    func typingPosture(from start: Double, to end: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let frames = history.filter { $0.time >= start && $0.time <= end }.map(\.state)
        guard frames.count >= 4 else { return false }
        let apart = frames.filter { $0 == "apart" }.count
        return Double(apart) / Double(frames.count) >= typingFrac
    }

    func secondsSinceHands(now: Double) -> Double { lock.lock(); defer { lock.unlock() }; return now - handsSeenAt }

    /// Feed one frame's hands. Returns true only on the frame that completes a vision double clap.
    @discardableResult
    func update(hands: [HandLandmarks], now: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        lastHandCount = hands.count
        if !hands.isEmpty { handsSeenAt = now }
        var fired = false
        if hands.count < 2 {
            append(now, hands.count == 1 ? "one" : "none")
            var merged = true
            if hands.count == 1, let lastMid {
                let palm = hands[0].palm
                merged = hypot(palm.x - lastMid.x, palm.y - lastMid.y) / hands[0].size < 1.6
            }
            if merged, hadTwo, armed, let lastDist, lastDist < nearR, approach > minApproach {
                fired = hit(now: now, direct: false)
            }
            hadTwo = false
            prevDist = nil
            if claps > 0, now - lastClapAt > gapMax { claps = 0 }
            return fired
        }
        let a = hands[0].palm, b = hands[1].palm
        let ref = Double((hands[0].size + hands[1].size) / 2)
        let dist = Double(hypot(a.x - b.x, a.y - b.y)) / ref
        if let prevDist, let prevTime {
            let dt = max(0.001, now - prevTime)
            let inst = (prevDist - dist) / dt
            approach = max(inst, approach * 0.6)
        }
        prevDist = dist
        prevTime = now
        lastDist = dist
        lastMid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        hadTwo = true
        append(now, dist >= apartR ? "apart" : "close")

        if armed {
            if dist < contactR, approach > minApproach { fired = hit(now: now, direct: true) }
        } else if dist > rearmR {
            armed = true
        } else if hitDirect, claps > 0, dist < contactR, now - hitAt > maxContactSec {
            claps = 0   // looked like a clap but turned into a grab
        }
        if claps == 1, now - lastClapAt > gapMax { claps = 0 }
        return fired
    }

    private func append(_ time: Double, _ state: String) {
        history.append((time, state))
        if history.count > 240 { history.removeFirst(history.count - 240) }
    }
}

/// Camera capture + Vision hand pose, feeding the vision detector at ~12 fps.
final class HandGate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let detector = VisionClapDetector()
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "atfm.handgate", qos: .userInitiated)
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private var lastFrameTime = 0.0
    private(set) var isRunning = false
    var onFrame: ((Int) -> Void)?   // hand count, for the UI
    var onVisionDoubleClap: ((Double) -> Void)?

    func start() throws {
        guard !isRunning else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "ATFM.Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "카메라를 찾지 못했어요"])
        }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NSError(domain: "ATFM.Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "카메라 입력을 추가하지 못했어요"]) }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw NSError(domain: "ATFM.Camera", code: 3, userInfo: [NSLocalizedDescriptionKey: "카메라 출력을 추가하지 못했어요"]) }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        isRunning = false
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 1.0 / 12.0, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = now
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return }
        let hands = (request.results ?? []).compactMap(Self.landmarks(from:))
        if detector.update(hands: hands, now: now) {
            onVisionDoubleClap?(now)
        }
        onFrame?(hands.count)
    }

    private static func landmarks(from observation: VNHumanHandPoseObservation) -> HandLandmarks? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence > 0.3 else { return nil }
            return CGPoint(x: p.location.x, y: 1 - p.location.y)   // top-left origin like MediaPipe
        }
        guard let wrist = point(.wrist), let index = point(.indexMCP), let middle = point(.middleMCP),
              let ring = point(.ringMCP), let little = point(.littleMCP) else { return nil }
        return HandLandmarks(wrist: wrist, indexMCP: index, middleMCP: middle, ringMCP: ring, littleMCP: little)
    }
}
