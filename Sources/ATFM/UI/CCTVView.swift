import SwiftUI

struct CCTVView: View {
    @Bindable var monitor: CCTVMonitor
    @Environment(\.colorScheme) private var scheme
    @State private var showGuide = false
    @State private var editingURL = false
    @State private var urlDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                previewCard
                controls
                if monitor.permissionDenied { permissionCard }
                if let error = monitor.errorText {
                VStack(alignment: .leading, spacing: 3) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    if monitor.sourceMode == .stream {
                        Text("폰 쪽: IP 카메라 앱이 꺼지거나 화면이 꺼지며 잠들면 스트림이 끊겨요. IP Webcam이면 설정 › '백그라운드에서 실행'과 배터리 최적화 제외를 켜고, 연결되면 여기서 자동으로 다시 붙어요.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 4)
            }
                motionCard
                if !monitor.events.isEmpty { eventsCard }
                guideCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            SectionLabel(text: "퀵 CCTV")
            Circle().fill(monitor.isRunning ? Color.green : (monitor.userStarted ? Color.orange : Color.secondary.opacity(0.4))).frame(width: 7, height: 7)
            Text(monitor.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if monitor.isRunning, monitor.fps > 0 {
                Text("\(Int(monitor.fps.rounded())) fps").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        ZStack {
            Color.black
            switch monitor.sourceMode {
            case .camera:
                if monitor.isRunning { CameraPreview(session: monitor.session) } else { placeholder }
            case .stream, .sample:
                if let image = monitor.latestImage, monitor.isRunning {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else { placeholder }
            }
            if monitor.isRunning { overlayHUD }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: monitor.userStarted ? "antenna.radiowaves.left.and.right" : "video.slash")
                .font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            Text(monitor.userStarted ? monitor.status : "시작을 누르면 카메라 영상이 여기 보여요")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
        .padding(16)
    }

    private var overlayHUD: some View {
        VStack {
            HStack {
                Label(sourceLabel, systemImage: monitor.sourceMode == .camera ? (monitor.selectedCamera?.isContinuity == true ? "iphone" : "camera") : "network")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.45)))
                Spacer()
                if monitor.isReconnecting {
                    Label("재연결 중", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.orange.opacity(0.8)))
                }
                if monitor.isRecording {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("REC \(recordingText)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.45)))
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if monitor.motionEnabled {
                    Image(systemName: "figure.walk.motion").font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(motionColor).frame(width: geo.size.width * min(1, monitor.motionLevel / 0.3))
                        }
                    }
                    .frame(height: 5)
                    if let last = monitor.lastMotionAt {
                        Text(CCTVMonitor.timeFormatter.string(from: last)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
                if let size = monitor.frameSize {
                    Text("\(Int(size.width))×\(Int(size.height))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(8)
    }

    private var motionColor: Color {
        monitor.motionLevel >= CCTVMonitor.threshold(for: monitor.sensitivity) ? .red : .green
    }

    private var sourceLabel: String {
        switch monitor.sourceMode {
        case .camera: return monitor.selectedCamera?.name ?? "카메라"
        case .stream: return URL(string: monitor.streamURL)?.host ?? "스트림"
        case .sample: return "샘플 영상"
        }
    }

    private var recordingText: String {
        guard let start = monitor.recordingStartedAt else { return "" }
        let seconds = Int(Date().timeIntervalSince(start))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                sourceMenu
                Spacer()
                Button {
                    monitor.toggle()
                } label: {
                    Label(monitor.userStarted ? "정지" : "시작", systemImage: monitor.userStarted ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(monitor.userStarted ? Color.red.opacity(0.85) : Theme.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                iconButton("camera.fill", "스냅샷", enabled: monitor.isRunning) { monitor.snapshot() }
                iconButton(monitor.isRecording ? "stop.circle.fill" : "record.circle", monitor.isRecording ? "녹화 중지" : "녹화", enabled: monitor.canRecord || monitor.isRecording, tint: monitor.isRecording ? .red : nil) { monitor.toggleRecording() }
                iconButton(monitor.showFloating ? "pip.exit" : "pip.enter", "플로팅 창", enabled: true, tint: monitor.showFloating ? Theme.accent : nil) { monitor.showFloating.toggle() }
                Spacer()
                Menu {
                    Button("스냅샷 폴더 열기") { monitor.openSnapshotFolder() }
                    Button("녹화 폴더 열기") { monitor.openMovieFolder() }
                    if let last = monitor.lastSnapshotURL { Button("마지막 스냅샷 보기") { NSWorkspace.shared.open(last) } }
                } label: { Image(systemName: "folder").font(.system(size: 13)) }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    private var sourceMenu: some View {
        Menu {
            Section("카메라") {
                if monitor.cameras.isEmpty { Text("카메라 없음") }
                ForEach(monitor.cameras) { camera in
                    Button {
                        monitor.sourceMode = .camera
                        monitor.selectedCameraID = camera.id
                    } label: {
                        let selected = monitor.sourceMode == .camera && monitor.selectedCameraID == camera.id
                        Label(camera.name + (camera.isContinuity ? " (iPhone)" : ""), systemImage: selected ? "checkmark" : (camera.isContinuity ? "iphone" : "camera"))
                    }
                }
                Button("다시 찾기") { monitor.refreshCameras() }
            }
            Section("스트림") {
                Button {
                    urlDraft = monitor.streamURL
                    editingURL = true
                } label: { Label(monitor.streamURL.isEmpty ? "MJPEG 주소 입력…" : "주소: \(monitor.streamURL)", systemImage: monitor.sourceMode == .stream ? "checkmark" : "network") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: monitor.sourceMode == .camera ? (monitor.selectedCamera?.isContinuity == true ? "iphone" : "camera") : "network")
                    .font(.system(size: 11, weight: .medium))
                Text(sourceLabel).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .popover(isPresented: $editingURL, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MJPEG 스트림 주소").font(.system(size: 12, weight: .semibold))
                Text("폰의 IP 카메라 앱(IP Webcam, DroidCam 등)이 보여주는 http://…/video 주소").font(.system(size: 10.5)).foregroundStyle(.secondary)
                TextField("http://192.168.0.12:8080/video", text: $urlDraft).textFieldStyle(.roundedBorder).frame(width: 280)
                    .onSubmit { applyURL() }
                HStack { Spacer(); Button("연결") { applyURL() }.controlSize(.small).keyboardShortcut(.defaultAction) }
            }
            .padding(12)
        }
    }

    private func applyURL() {
        monitor.streamURL = urlDraft.trimmingCharacters(in: .whitespaces)
        monitor.sourceMode = .stream
        editingURL = false
        if !monitor.userStarted { monitor.start() }
    }

    private func iconButton(_ symbol: String, _ title: String, enabled: Bool, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.chipFill(scheme)))
                .foregroundStyle(tint ?? (enabled ? Color.primary : Color.secondary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Motion

    private var motionCard: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "figure.walk.motion", title: "움직임 감지", subtitle: monitor.motionEnabled ? "화면이 바뀌면 기록해요 · 탭을 닫아도 계속" : "켜면 말풍선을 닫아도 카메라를 계속 봐요") {
                Toggle("", isOn: $monitor.motionEnabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if monitor.motionEnabled {
                Divider().padding(.horizontal, 14)
                ActionRow(icon: "slider.horizontal.3", title: "민감도", subtitle: "오른쪽일수록 작은 움직임도 잡아요") {
                    Slider(value: $monitor.sensitivity, in: 0.2...1).controlSize(.small).frame(width: 110)
                }
                Divider().padding(.horizontal, 14)
                HStack(spacing: 14) {
                    Toggle("알림", isOn: $monitor.notifyOnMotion)
                    Toggle("스냅샷 저장", isOn: $monitor.snapshotOnMotion)
                    Toggle("10초 클립 녹화", isOn: $monitor.recordOnMotion).disabled(monitor.sourceMode != .camera)
                    Spacer()
                }
                .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .card()
    }

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("감지 기록").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("지우기") { monitor.clearEvents() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            ForEach(monitor.events.prefix(8)) { event in
                HStack(spacing: 10) {
                    if let thumb = event.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill).frame(width: 56, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)).frame(width: 56, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CCTVMonitor.timeFormatter.string(from: event.date)).font(.system(size: 12, weight: .medium))
                        Text("변화 \(Int(min(1, event.level / 0.3) * 100))%" + (event.snapshotURL != nil ? " · 스냅샷 저장됨" : "")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = event.snapshotURL {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
            }
            Spacer().frame(height: 6)
        }
        .card()
    }

    private var permissionCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("카메라 권한이 필요해요").font(.system(size: 12, weight: .semibold))
                Text("시스템 설정 › 개인정보 보호 및 보안 › 카메라에서 ATFM을 켜 주세요").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("설정 열기") { monitor.openCameraSettings() }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { showGuide.toggle() } } label: {
                HStack {
                    Label("폰을 카메라로 쓰는 법 (iPhone · Android)", systemImage: "iphone.radiowaves.left.and.right").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: showGuide ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showGuide {
                VStack(alignment: .leading, spacing: 6) {
                    Text("iPhone · 연속성 카메라 (앱 설치 없음)").font(.system(size: 11, weight: .semibold)).padding(.top, 2)
                    guideLine("1", "iPhone(iOS 16+)과 Mac이 같은 Apple 계정 · Wi-Fi · 블루투스 켜기, iPhone 설정 › 일반 › AirPlay 및 연속성 › 연속성 카메라 켜기")
                    guideLine("2", "폰을 잠그고 가로로 세워 두면(뒤 카메라가 보고 싶은 쪽) 위 목록에 'OO의 iPhone 카메라'가 나타나요. 블루투스 거리(같은 집 정도) 안에서만")
                    Text("Android · 또는 멀리 있는 iPhone (IP 카메라 앱)").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
                    guideLine("1", "폰에 'IP Webcam'(Android) 같은 IP 카메라 앱을 깔고 서버 시작 → 앱이 보여주는 주소(예: http://192.168.0.12:8080)를 확인")
                    guideLine("2", "위 카메라 메뉴 › MJPEG 주소 입력에 그 주소 뒤에 /video 를 붙여 넣기 (IP Webcam은 http://…:8080/video). 같은 Wi-Fi면 바로 연결돼요")
                    guideLine("3", "집 밖에서 보려면 앱의 공유/터널 기능이나 Tailscale 같은 VPN으로 폰 주소에 닿게 하면 돼요")
                    Text("공통").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
                    guideLine("•", "'움직임 감지'를 켜 두면 말풍선을 닫아도 감시가 이어지고, 감지되면 알림 · 스냅샷(사진 › ATFM CCTV) · 클립(동영상 › ATFM CCTV)")
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .card()
    }

    private func guideLine(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent).frame(width: 14, alignment: .trailing)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Content of the floating always-on-top window.
struct CCTVFloatingView: View {
    @Bindable var monitor: CCTVMonitor

    var body: some View {
        ZStack {
            Color.black
            switch monitor.sourceMode {
            case .camera:
                if monitor.isRunning { CameraPreview(session: monitor.session) }
            case .stream, .sample:
                if let image = monitor.latestImage { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            }
            if !monitor.isRunning {
                Text(monitor.userStarted ? monitor.status : "탭에서 시작을 누르세요").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            VStack {
                HStack {
                    if monitor.motionEnabled, let last = monitor.lastMotionAt, Date().timeIntervalSince(last) < 5 {
                        Label("움직임", systemImage: "figure.walk.motion").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(Capsule().fill(Color.red.opacity(0.8)))
                    }
                    Spacer()
                    if monitor.isRecording { Circle().fill(Color.red).frame(width: 8, height: 8) }
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(minWidth: 200, minHeight: 130)
    }
}
