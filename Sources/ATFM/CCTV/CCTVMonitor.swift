import AppKit
import AVFoundation
import CoreImage
import Observation
import SwiftUI
import UserNotifications

/// 퀵 CCTV: watch an iPhone (Continuity Camera), the Mac's camera, or an MJPEG stream from any IP-camera
/// app, with motion detection (notification · snapshot · clip), snapshots, recording and a floating window.
@MainActor
@Observable
final class CCTVMonitor {
    enum SourceMode: String { case camera, stream, sample }

    struct CameraOption: Identifiable, Equatable {
        let id: String
        let name: String
        let isContinuity: Bool
        let isBuiltIn: Bool
    }

    struct MotionEvent: Identifiable {
        let id = UUID()
        let date: Date
        let level: Double
        let thumbnail: NSImage?
        let snapshotURL: URL?
    }

    // Source
    private(set) var cameras: [CameraOption] = []
    var selectedCameraID: String? {
        didSet { UserDefaults.standard.set(selectedCameraID, forKey: "cctvCamera"); if userStarted { restart() } }
    }
    var streamURL: String {
        didSet { if persistSettings { UserDefaults.standard.set(streamURL, forKey: "cctvStreamURL") } }
    }
    var sourceMode: SourceMode {
        didSet { if persistSettings { UserDefaults.standard.set(sourceMode.rawValue, forKey: "cctvSource") }; if userStarted { restart() } }
    }

    // State
    private(set) var userStarted = false
    private(set) var isRunning = false
    private(set) var status = "대기"
    private(set) var errorText: String?
    private(set) var permissionDenied = false
    private(set) var frameSize: CGSize?
    private(set) var fps: Double = 0
    private(set) var latestImage: NSImage?          // stream / sample modes (the camera mode draws through the preview layer)
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var lastSnapshotURL: URL?

    // Motion
    @ObservationIgnored private var persistSettings = true
    var motionEnabled: Bool { didSet { if persistSettings { UserDefaults.standard.set(motionEnabled, forKey: "cctvMotion") }; updateRunning() } }
    var sensitivity: Double { didSet { UserDefaults.standard.set(sensitivity, forKey: "cctvSensitivity") } }
    var notifyOnMotion: Bool { didSet { UserDefaults.standard.set(notifyOnMotion, forKey: "cctvNotify") } }
    var snapshotOnMotion: Bool { didSet { UserDefaults.standard.set(snapshotOnMotion, forKey: "cctvSnapshot") } }
    var recordOnMotion: Bool { didSet { UserDefaults.standard.set(recordOnMotion, forKey: "cctvRecordClip") } }
    private(set) var motionLevel: Double = 0
    private(set) var lastMotionAt: Date?
    private(set) var events: [MotionEvent] = []

    // Floating window
    var showFloating = false {
        didSet { showFloating ? floatingWindow.show(monitor: self) : floatingWindow.hide(); updateRunning() }
    }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored var debugLog: ((String) -> Void)?
    @ObservationIgnored var notify: ((String, String) -> Void)?
    @ObservationIgnored private let queue = DispatchQueue(label: "atfm.cctv", qos: .userInitiated)
    @ObservationIgnored private let tap = FrameTap()
    @ObservationIgnored private let recordingDelegate = RecordingDelegate()
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()
    @ObservationIgnored private let detector = MotionDetector()
    @ObservationIgnored private var tabVisible = false
    @ObservationIgnored private var mjpeg: MJPEGClient?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempts = 0
    private(set) var isReconnecting = false
    @ObservationIgnored private var sampleTimer: Timer?
    @ObservationIgnored private var sampleTick = 0
    @ObservationIgnored private var clipStopTask: Task<Void, Never>?
    @ObservationIgnored private var lastEventAt = Date.distantPast
    @ObservationIgnored private let floatingWindow = CCTVFloatingWindow()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let ciContext = CIContext()

    static let snapshotFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!.appendingPathComponent("ATFM CCTV")
    static let movieFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("ATFM CCTV")

    init() {
        let defaults = UserDefaults.standard
        selectedCameraID = defaults.string(forKey: "cctvCamera")
        streamURL = defaults.string(forKey: "cctvStreamURL") ?? ""
        sourceMode = SourceMode(rawValue: defaults.string(forKey: "cctvSource") ?? "") ?? .camera
        motionEnabled = defaults.bool(forKey: "cctvMotion")
        let storedSensitivity = defaults.double(forKey: "cctvSensitivity")
        sensitivity = storedSensitivity > 0 ? storedSensitivity : 0.6
        notifyOnMotion = defaults.object(forKey: "cctvNotify") as? Bool ?? true
        snapshotOnMotion = defaults.object(forKey: "cctvSnapshot") as? Bool ?? true
        recordOnMotion = defaults.bool(forKey: "cctvRecordClip")
        refreshCameras()
        wireCallbacks()
        observeDevices()
        if ProcessInfo.processInfo.environment["ATFM_DEBUG_CCTV_SAMPLE"] == "1" {   // generated feed, nothing persisted
            persistSettings = false
            sourceMode = .sample
            motionEnabled = true
            start()
        } else if let url = ProcessInfo.processInfo.environment["ATFM_DEBUG_CCTV_STREAM"] {   // MJPEG url, nothing persisted
            persistSettings = false
            streamURL = url
            sourceMode = .stream
            motionEnabled = true
            start()
        }
        if ProcessInfo.processInfo.environment["ATFM_DEBUG_CCTV_LOG"] == "1" { debugLog = { NSLog("ATFM cctv: %@", $0) } }
    }

    // MARK: Cameras

    func refreshCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
                                                         mediaType: .video, position: .unspecified)
        cameras = discovery.devices.map {
            CameraOption(id: $0.uniqueID, name: $0.localizedName, isContinuity: $0.deviceType == .continuityCamera,
                         isBuiltIn: $0.deviceType == .builtInWideAngleCamera)
        }
        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            let preferred = cameras.first(where: \.isContinuity) ?? cameras.first
            if preferred?.id != selectedCameraID { selectedCameraID = preferred?.id }
        }
    }

    var selectedCamera: CameraOption? { cameras.first { $0.id == selectedCameraID } }
    var continuityCamera: CameraOption? { cameras.first(where: \.isContinuity) }

    private func observeDevices() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let wasSelected = (note.object as? AVCaptureDevice)?.uniqueID == self.selectedCameraID
                    self.refreshCameras()
                    if name == AVCaptureDevice.wasDisconnectedNotification, wasSelected, self.userStarted {
                        self.status = "카메라 연결이 끊겼어요"
                        self.restart()
                    } else if name == AVCaptureDevice.wasConnectedNotification, self.userStarted, self.sourceMode == .camera, !self.isRunning {
                        self.restart()
                    }
                }
            })
        }
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.errorText = error?.localizedDescription ?? "카메라 세션 오류"
                self?.isRunning = false
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.status = "다른 앱이 카메라를 쓰고 있어요" }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.status = "실시간" }
        })
    }

    private func wireCallbacks() {
        tap.onFrame = { [weak self] buffer, size in self?.handleFrame(buffer, size: size) }   // capture queue
        tap.onFPS = { [weak self] fps in Task { @MainActor in self?.fps = fps } }
        recordingDelegate.onFinish = { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.recordingStartedAt = nil
                if let error { self.errorText = "녹화 실패: \(error.localizedDescription)" } else { self.status = "녹화 저장됨 · \(url.lastPathComponent)" }
                self.updateRunning()
            }
        }
    }

    // MARK: Start / stop

    func setTabVisible(_ visible: Bool) {
        tabVisible = visible
        updateRunning()
    }

    func start() {
        userStarted = true
        errorText = nil
        updateRunning()
    }

    func stop() {
        userStarted = false
        if isRecording { stopRecording() }
        updateRunning()
    }

    func toggle() { userStarted ? stop() : start() }

    private func restart() {
        guard userStarted else { return }
        tearDownSource()
        updateRunning()
    }

    /// The feed runs while the user has started it and something is looking at it (tab, floating window,
    /// motion watch, recording); otherwise it pauses so a phone camera isn't left on for nothing.
    private var wantsRunning: Bool {
        userStarted && (tabVisible || motionEnabled || showFloating || isRecording)
    }

    private func updateRunning() {
        if wantsRunning {
            if !isRunning { startSource() }
        } else if isRunning {
            tearDownSource()
            status = userStarted ? "일시 정지 · 탭을 열거나 움직임 감지를 켜면 다시 연결" : "대기"
        }
    }

    private func startSource() {
        detector.reset()
        switch sourceMode {
        case .camera: startCamera()
        case .stream: startStream()
        case .sample: startSample()
        }
    }

    private func tearDownSource() {
        if session.isRunning || !session.inputs.isEmpty {
            queue.async { [session] in
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration()
                if session.isRunning { session.stopRunning() }
            }
        }
        mjpeg?.stop()
        mjpeg = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        isReconnecting = false
        sampleTimer?.invalidate()
        sampleTimer = nil
        isRunning = false
        fps = 0
        motionLevel = 0
    }

    private func startCamera() {
        guard let id = selectedCameraID, let device = AVCaptureDevice(uniqueID: id) else {
            status = cameras.isEmpty ? "카메라를 찾지 못했어요" : "카메라를 골라 주세요"
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun(device)
        case .notDetermined:
            status = "카메라 권한 요청 중…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionDenied = !granted
                    if granted, self.wantsRunning { self.configureAndRun(device) } else { self.status = "카메라 권한이 없어요" }
                }
            }
        default:
            permissionDenied = true
            status = "카메라 권한이 없어요"
        }
    }

    private func configureAndRun(_ device: AVCaptureDevice) {
        permissionDenied = false
        status = "연결 중… \(device.localizedName)"
        let tap = tap
        let movieOutput = movieOutput
        queue.async { [session] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
            var failure: String?
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) } else { failure = "입력을 추가할 수 없어요" }
            } catch { failure = error.localizedDescription }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.setSampleBufferDelegate(tap, queue: self.queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            session.commitConfiguration()
            if failure == nil { session.startRunning() }
            let running = session.isRunning
            Task { @MainActor in
                if let failure { self.errorText = failure; self.status = "연결 실패"; self.isRunning = false }
                else { self.isRunning = running; self.status = running ? "실시간 · \(device.localizedName)" : "카메라를 시작하지 못했어요" }
            }
        }
    }

    private func startStream() {
        guard let url = MJPEGClient.normalize(streamURL), url.host != nil else {
            status = "스트림 주소를 입력해 주세요 (예: http://192.168.0.12:8080/video)"
            return
        }
        status = reconnectAttempts == 0 ? "연결 중… \(url.host ?? "")" : "재연결 중… \(reconnectAttempts)회"
        debugLog?("stream connect attempt \(reconnectAttempts) \(url.absoluteString)")
        let client = MJPEGClient(url: url)
        client.onFrame = { [weak self] image in Task { @MainActor in self?.handleImage(image) } }
        client.onConnected = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectAttempts = 0
                self.isReconnecting = false
                self.errorText = nil
                self.status = "실시간 · \(connected.host ?? "")\(connected.path)"
                self.debugLog?("stream connected \(connected.absoluteString)")
                if connected.absoluteString != self.streamURL { self.streamURL = connected.absoluteString }   // remember the endpoint that worked
            }
        }
        client.onError = { [weak self] message in Task { @MainActor in self?.streamFailed(message) } }
        client.start()
        mjpeg = client
        isRunning = true
    }

    /// Streams drop when the phone sleeps or the app is paused: keep the last frame and retry with backoff
    /// (3 · 5 · 8 · 12 · 15 s) for as long as the user leaves it started.
    private func streamFailed(_ message: String) {
        guard userStarted, sourceMode == .stream else { return }
        debugLog?("stream failed: \(message)")
        mjpeg?.stop()
        mjpeg = nil
        fps = 0
        motionLevel = 0
        reconnectAttempts += 1
        isReconnecting = true
        errorText = message
        let delays: [Double] = [3, 5, 8, 12, 15]
        let delay = delays[min(reconnectAttempts - 1, delays.count - 1)]
        status = "연결이 끊겨 \(Int(delay))초 뒤 다시 시도 (\(reconnectAttempts)회)"
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.userStarted, self.sourceMode == .stream, self.wantsRunning else { return }
            self.startStream()
        }
    }

    private func startSample() {
        status = "샘플 영상"
        isRunning = true
        sampleTick = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sampleTick += 1
                self.handleImage(SampleFeed.frame(tick: self.sampleTick))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    // MARK: Frames

    private var frameCounter = 0

    /// Capture-queue path (camera mode).
    private func handleFrame(_ buffer: CVPixelBuffer, size: CGSize) {
        let level = detector.process(pixelBuffer: buffer)
        tap.latestBuffer = buffer
        Task { @MainActor in
            if self.frameSize != size { self.frameSize = size }
            self.publishMotion(level)
        }
    }

    /// Main-actor path (stream / sample modes).
    private func handleImage(_ image: NSImage) {
        latestImage = image
        if frameSize != image.size { frameSize = image.size }
        frameCounter += 1
        if frameCounter % 2 == 0 { publishMotion(detector.process(image: image)) }
        if frameCounter % 10 == 0 { fps = sourceMode == .sample ? 10 : fps }
    }

    private func publishMotion(_ level: Double) {
        guard isRunning else { return }
        motionLevel = level
        guard motionEnabled else { return }
        let threshold = Self.threshold(for: sensitivity)
        if level >= threshold {
            lastMotionAt = Date()
            if recordOnMotion { extendClip() }
            if Date().timeIntervalSince(lastEventAt) > 8 { lastEventAt = Date(); recordEvent(level: level) }
        }
    }

    /// Fraction of grid cells that must change: 0.5% at max sensitivity, ~5% at the default 0.6, 10% at the minimum.
    static func threshold(for sensitivity: Double) -> Double { 0.005 + (1 - sensitivity) * 0.12 }

    private func recordEvent(level: Double) {
        let image = currentImage()
        var url: URL?
        if snapshotOnMotion, let image { url = save(image: image, prefix: "motion") }
        let thumb = image.map { Self.thumbnail($0, width: 160) }
        events.insert(MotionEvent(date: Date(), level: level, thumbnail: thumb, snapshotURL: url), at: 0)
        if events.count > 40 { events.removeLast(events.count - 40) }
        let time = Self.timeFormatter.string(from: Date())
        notify?("움직임 감지", time)
        if notifyOnMotion { postNotification(title: "퀵 CCTV · 움직임 감지", body: "\(time) · \(selectedCamera?.name ?? "카메라")") }
    }

    // MARK: Snapshots & recording

    func currentImage() -> NSImage? {
        switch sourceMode {
        case .camera:
            guard let buffer = tap.latestBuffer else { return nil }
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        case .stream, .sample:
            return latestImage
        }
    }

    @discardableResult
    func snapshot() -> URL? {
        guard let image = currentImage() else { status = "아직 영상이 없어요"; return nil }
        let url = save(image: image, prefix: "snapshot")
        lastSnapshotURL = url
        if let url { status = "스냅샷 저장됨 · \(url.lastPathComponent)"; notify?("스냅샷 저장", url.lastPathComponent) }
        return url
    }

    private func save(image: NSImage, prefix: String) -> URL? {
        let folder = Self.snapshotFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(prefix) \(Self.fileFormatter.string(from: Date())).jpg"
        let url = folder.appendingPathComponent(name)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        try? data.write(to: url)
        return url
    }

    var canRecord: Bool { sourceMode == .camera && isRunning }

    func startRecording() {
        guard canRecord, !isRecording else { return }
        try? FileManager.default.createDirectory(at: Self.movieFolder, withIntermediateDirectories: true)
        let url = Self.movieFolder.appendingPathComponent("clip \(Self.fileFormatter.string(from: Date())).mov")
        isRecording = true
        recordingStartedAt = Date()
        status = "녹화 중"
        let output = movieOutput, delegate = recordingDelegate
        queue.async { output.startRecording(to: url, recordingDelegate: delegate) }
    }

    func stopRecording() {
        guard isRecording else { return }
        clipStopTask?.cancel()
        let output = movieOutput
        queue.async { if output.isRecording { output.stopRecording() } }
    }

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    /// Motion clip: start recording on motion and keep going until 10 s after the last movement.
    private func extendClip() {
        guard sourceMode == .camera else { return }
        if !isRecording { startRecording() }
        clipStopTask?.cancel()
        clipStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.stopRecording()
        }
    }

    func openSnapshotFolder() {
        try? FileManager.default.createDirectory(at: Self.snapshotFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.snapshotFolder)
    }

    func openMovieFolder() {
        try? FileManager.default.createDirectory(at: Self.movieFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.movieFolder)
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
    }

    func clearEvents() { events.removeAll() }

    // MARK: Helpers

    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let send = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            switch settings.authorizationStatus {
            case .notDetermined: center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
            case .denied: break
            default: send()
            }
        }
    }

    static func thumbnail(_ image: NSImage, width: CGFloat) -> NSImage {
        let scale = width / max(image.size.width, 1)
        let size = NSSize(width: width, height: max(1, image.size.height * scale))
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "a h:mm:ss"; return f }()
    static let fileFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f }()
}

// MARK: - Capture helpers (nonisolated)

final class FrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: ((CVPixelBuffer, CGSize) -> Void)?
    var onFPS: ((Double) -> Void)?
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    var latestBuffer: CVPixelBuffer? {
        get { lock.lock(); defer { lock.unlock() }; return _latest }
        set { lock.lock(); _latest = newValue; lock.unlock() }
    }
    private var count = 0
    private var windowStart = Date()
    private var frameIndex = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        count += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 { onFPS?(Double(count) / elapsed); count = 0; windowStart = Date() }
        frameIndex += 1
        guard frameIndex % 3 == 0 else { return }      // ~10 analyses per second is plenty
        onFrame?(buffer, CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
    }
}

final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    var onFinish: ((URL, Error?) -> Void)?
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        onFinish?(outputFileURL, error)
    }
}

/// Frame differencing on a coarse luma grid: the fraction of cells whose brightness changed.
final class MotionDetector: @unchecked Sendable {
    private let columns = 32, rows = 18
    private var previous: [UInt8]?
    private let lock = NSLock()

    func reset() { lock.lock(); previous = nil; lock.unlock() }

    func process(pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerPixel = planar ? 1 : 4
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var grid = [UInt8](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let cx = (column * width) / columns + width / (columns * 2)
                let cy = (row * height) / rows + height / (rows * 2)
                var sum = 0
                var n = 0
                var dy = -3
                while dy <= 3 {
                    var dx = -3
                    while dx <= 3 {
                        let x = min(max(0, cx + dx), width - 1), y = min(max(0, cy + dy), height - 1)
                        sum += Int(pointer[y * stride + x * bytesPerPixel + (planar ? 0 : 1)])
                        n += 1
                        dx += 2
                    }
                    dy += 2
                }
                grid[row * columns + column] = UInt8(sum / max(n, 1))
            }
        }
        return compare(grid)
    }

    func process(image: NSImage) -> Double {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        var grid = [UInt8](repeating: 0, count: columns * rows)
        guard let context = CGContext(data: &grid, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.interpolationQuality = .low
        context.draw(cg, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        return compare(grid)
    }

    private func compare(_ grid: [UInt8]) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let previous, previous.count == grid.count else { self.previous = grid; return 0 }
        var changed = 0
        for index in grid.indices where abs(Int(grid[index]) - Int(previous[index])) > 18 { changed += 1 }
        self.previous = grid
        return Double(changed) / Double(grid.count)
    }
}

/// Reads an MJPEG (multipart JPEG) HTTP stream and hands back decoded frames. Works with most
/// "IP camera" phone apps (IP Webcam, DroidCam, EpocCam…) that expose an http://…/video URL.
final class MJPEGClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var onFrame: ((NSImage) -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: ((URL) -> Void)?
    private let candidates: [URL]
    private var index = 0
    private var session: URLSession?
    private var buffer = Data()
    private var gotFrame = false
    private var sawHTML = false

    /// Endpoints tried after the exact URL when it has no path: IP Webcam, DroidCam, generic MJPEG servers.
    static let commonPaths = ["/video", "/videofeed", "/mjpeg", "/mjpg/video.mjpg", "/stream", "/cam/1/stream", "/?action=stream"]

    init(url: URL) {
        var list = [url]
        let path = url.path
        if path.isEmpty || path == "/" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            for extra in Self.commonPaths {
                let parts = extra.split(separator: "?", maxSplits: 1)
                components?.path = String(parts[0])
                components?.query = parts.count > 1 ? String(parts[1]) : nil
                if let candidate = components?.url { list.append(candidate) }
            }
        }
        candidates = list
    }

    /// Adds the scheme when the user typed a bare host, and never tries TLS on a plain IP-camera port.
    static func normalize(_ text: String) -> URL? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.contains("://") { string = "http://" + string }
        if string.hasPrefix("https://"), let host = URL(string: string)?.host, host.allSatisfy({ $0.isNumber || $0 == "." }) {
            string = "http://" + string.dropFirst("https://".count)      // IP camera apps serve plain http
        }
        return URL(string: string)
    }

    func start() { connect() }

    private func connect() {
        guard index < candidates.count else {
            onError?(sawHTML ? "주소가 웹페이지예요. 앱이 알려주는 영상 주소(예: IP Webcam은 …:8080/video)를 넣어 주세요"
                             : "영상 스트림을 찾지 못했어요. 폰 앱의 서버가 켜져 있고 같은 Wi-Fi인지 확인해 주세요")
            return
        }
        buffer.removeAll()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: candidates[index]).resume()
    }

    private func tryNext() {
        session?.invalidateAndCancel()
        session = nil
        index += 1
        connect()
    }

    func stop() {
        session?.invalidateAndCancel()
        session = nil
        index = candidates.count
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType ?? "").lowercased()
        if let code = http?.statusCode, code >= 400 {
            completionHandler(.cancel); tryNext(); return
        }
        if type.contains("text/html") {
            sawHTML = true
            completionHandler(.cancel); tryNext(); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if buffer.count > 8_000_000 { buffer.removeAll() }
        while let start = buffer.range(of: Data([0xFF, 0xD8, 0xFF])), let end = buffer.range(of: Data([0xFF, 0xD9]), in: start.upperBound..<buffer.endIndex) {
            let frame = buffer.subdata(in: start.lowerBound..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            if let image = NSImage(data: frame) {
                if !gotFrame { gotFrame = true; onConnected?(candidates[index]) }
                onFrame?(image)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // Clean close: the server stopped (phone app paused/quit). Treat it like a drop so the owner reconnects.
            if gotFrame { onError?("스트림이 끊겼어요 (폰 쪽에서 연결을 닫음)") }
            else if index + 1 < candidates.count { tryNext() }
            else { onError?("영상 없이 연결이 끝났어요. 폰 앱의 서버가 켜져 있는지 확인해 주세요") }
            return
        }
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if !gotFrame, index + 1 < candidates.count { tryNext(); return }
        let ns = error as NSError
        var message = error.localizedDescription
        if ns.code == NSURLErrorAppTransportSecurityRequiresSecureConnection { message = "http 연결이 막혔어요 (앱 전송 보안)" }
        if ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorTimedOut {
            message += " · 폰 앱의 서버가 켜져 있고 Mac과 같은 Wi-Fi인지, 시스템 설정 › 개인정보 보호 › 로컬 네트워크에서 ATFM이 허용됐는지 확인"
        }
        onError?(message)
    }
}

/// Generated frames for screenshots / development: a slow gradient with a wandering "visitor" every few seconds.
enum SampleFeed {
    static func frame(tick: Int) -> NSImage {
        let size = NSSize(width: 640, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.22, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.30, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 90)
        // room props
        NSColor(calibratedWhite: 0.32, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 60, y: 60, width: 220, height: 120)).fill()
        NSColor(calibratedWhite: 0.42, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 400, y: 70, width: 160, height: 200), xRadius: 8, yRadius: 8).fill()
        NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.22, alpha: 0.9).setFill(); NSBezierPath(ovalIn: NSRect(x: 560, y: 290, width: 40, height: 40)).fill()
        // visitor crossing every ~6 s
        let phase = (tick % 60)
        if phase < 30 {
            let x = CGFloat(phase) / 30 * 760 - 120
            NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.33, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 40, width: 110, height: 200), xRadius: 24, yRadius: 24).fill()
            NSColor(calibratedRed: 0.99, green: 0.85, blue: 0.75, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 20, y: 245, width: 70, height: 70)).fill()
        }
        let text = "CAM 1 · " + CCTVMonitor.timeFormatter.string(from: Date())
        (text as NSString).draw(at: NSPoint(x: 14, y: size.height - 30),
                                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        image.unlockFocus()
        return image
    }
}

// MARK: - Preview view & floating window

/// Hosts an AVCaptureVideoPreviewLayer for the camera mode.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: NSView {
        var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
        override func makeBackingLayer() -> CALayer {
            let layer = AVCaptureVideoPreviewLayer()
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = NSColor.black.cgColor
            return layer
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.wantsLayer = true
        view.previewLayer?.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        if view.previewLayer?.session !== session { view.previewLayer?.session = session }
    }
}

@MainActor
final class CCTVFloatingWindow: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var monitor: CCTVMonitor?

    func show(monitor: CCTVMonitor) {
        self.monitor = monitor
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "퀵 CCTV"
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 200, height: 130)
            panel.delegate = self
            panel.setFrameAutosaveName("cctvFloating")
            panel.contentView = NSHostingView(rootView: CCTVFloatingView(monitor: monitor))
            if panel.frame.origin == .zero { panel.center() }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func windowWillClose(_ notification: Notification) {
        monitor?.showFloating = false
    }
}
