import SwiftUI

struct ChatPrivacyView: View {
    @Bindable var privacy: ChatPrivacyMode
    var hotkeys: ToolHotkeys
    @Environment(\.colorScheme) private var scheme
    @State private var editing: PrivacyTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "채팅 프라이버시")
                    Spacer()
                    Toggle("", isOn: Binding(get: { privacy.isEnabled }, set: { privacy.setEnabled($0, announce: false) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                statusCard
                optionsCard
                appsCard
                Text("메신저가 맨 앞에 있을 때만 그 창 위에 유리판을 띄우는 방식이라 앱 자체는 건드리지 않고, 클릭·스크롤도 그대로 통과해요. 브라우저 탭 조건(창 제목)은 화면 기록 권한이 있어야 읽혀요.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: Status + hotkey

    private var statusCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: privacy.isEnabled ? "eye.slash.fill" : "eye")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(privacy.isEnabled ? Theme.accent : Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(privacy.isEnabled ? (privacy.activeName.map { "\($0) 창 가리는 중" } ?? "켜짐 · 메신저가 앞에 오면 가려요") : "꺼짐")
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(privacy.lastError == nil ? Color.secondary : Color.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().padding(.horizontal, 14)
            HotkeyRow(action: .chatPrivacy, hotkeys: hotkeys)
            if let message = hotkeys.message, hotkeys.recording == nil {
                Text(message).font(.system(size: 10.5)).foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
        .card()
    }

    private var statusDetail: String {
        if let error = privacy.lastError { return error }
        if privacy.isEnabled, privacy.activeName != nil {
            return "최근 \(privacy.visibleMessages)개 메시지와 입력창만 보여요" + (privacy.headerDetected ? " · 헤더 자동 감지" : "")
        }
        return "가장 최근 \(privacy.recentCount)개 메시지와 지금 쓰는 글만 남기고 흐리게"
    }

    // MARK: Options

    private var optionsCard: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "text.bubble", title: "보이는 최근 메시지", subtitle: "이 개수만큼은 흐리지 않아요") {
                HStack(spacing: 6) {
                    Text("\(privacy.recentCount)개").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    Stepper("", value: $privacy.recentCount, in: 1...5).labelsHidden().controlSize(.small)
                }
            }
            Divider().padding(.horizontal, 14)
            ActionRow(icon: "water.waves", title: "가장자리 부드러움", subtitle: "클수록 경계가 안 보이지만 그 위 메시지가 살짝 비쳐요") {
                HStack(spacing: 6) {
                    Slider(value: $privacy.featherSize, in: 8...120, step: 4).controlSize(.small).frame(width: 110)
                    Text("\(Int(privacy.featherSize))").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 26, alignment: .trailing)
                }
            }
            Divider().padding(.horizontal, 14)
            ActionRow(icon: "circle.lefthalf.filled", title: "유리 톤", subtitle: "자동은 시스템 외관을 따라가요") {
                Picker("", selection: $privacy.tone) {
                    ForEach(PrivacyOverlay.Tone.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
            }
        }
        .card()
    }

    // MARK: Apps

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("적용할 앱").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    let apps = privacy.addableApps
                    if apps.isEmpty { Text("추가할 수 있는 앱이 없어요") }
                    ForEach(apps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") { privacy.add(app: app) }
                    }
                } label: {
                    Label("실행 중인 앱 추가", systemImage: "plus").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            let targets = privacy.visibleTargets
            if targets.isEmpty {
                Text("설치된 메신저를 찾지 못했어요. 위 메뉴에서 실행 중인 앱을 추가해 보세요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            ForEach(targets) { target in
                TargetRow(target: target, privacy: privacy, isActive: privacy.activeName == target.name) { editing = target }
            }
            Spacer().frame(height: 6)
        }
        .card()
        .popover(item: $editing, arrowEdge: .top) { target in
            TargetEditor(target: target, privacy: privacy) { editing = nil }
        }
    }
}

private struct TargetRow: View {
    let target: PrivacyTarget
    let privacy: ChatPrivacyMode
    let isActive: Bool
    let edit: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ProcessIcon(bundlePath: target.appIconPath, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(target.name).font(.system(size: 12, weight: .medium))
                    if isActive {
                        Text("가리는 중").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                    }
                }
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hovering {
                Button(action: edit) { Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("창 제목 조건 · 위쪽 여백 · 입력창 높이")
            }
            Toggle("", isOn: Binding(get: { target.enabled }, set: { privacy.setTarget(target.id, enabled: $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(hovering ? Theme.hoverFill(scheme) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("설정…", action: edit)
            if !target.isPreset { Button("목록에서 제거") { privacy.remove(target.id) } }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let urls = target.urlKeywords, !urls.isEmpty { parts.append("탭 주소 \(urls.first ?? "")") }
        else if let keyword = target.titleKeyword, !keyword.isEmpty { parts.append("창 제목에 '\(keyword)'") }
        if let excluded = target.excludedTitles, !excluded.isEmpty { parts.append("채팅방 창만") }
        if target.topInset > 0 { parts.append("헤더 \(Int(target.topInset))px") }
        parts.append("입력창 \(Int(target.composerHeight))px")
        return parts.joined(separator: " · ")
    }
}

private struct TargetEditor: View {
    @State var target: PrivacyTarget
    let privacy: ChatPrivacyMode
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.name).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("창 제목 조건 (비우면 모든 창)").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("예: Google Chat", text: Binding(get: { target.titleKeyword ?? "" }, set: { target.titleKeyword = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
            }
            if target.supportsURLCheck || target.urlKeywords != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("앞 탭 주소에 포함 (쉼표로 여러 개 · a*b는 둘 다 포함, 비우면 안 씀)").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("예: chat.google.com, google.com*#chat",
                              text: Binding(get: { (target.urlKeywords ?? []).joined(separator: ", ") },
                                            set: { text in
                                                let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                                target.urlKeywords = parts.isEmpty ? nil : parts
                                            }))
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                }
            }
            stepper("헤더 높이 (색으로 못 찾을 때 기본값)", value: $target.topInset, range: 0...300, step: 4)
            stepper("입력창 높이 (아래에서, 가리지 않음)", value: $target.composerHeight, range: 40...300, step: 10)
            HStack {
                Spacer()
                Button("완료") { privacy.update(target); done() }.keyboardShortcut(.defaultAction).controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func stepper(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text("\(Int(value.wrappedValue))px").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            Stepper("", value: value, in: range, step: step).labelsHidden().controlSize(.small)
        }
    }
}
