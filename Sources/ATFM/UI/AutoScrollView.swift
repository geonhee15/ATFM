import SwiftUI

struct AutoScrollView: View {
    @Bindable var scroller: AutoScroller
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                toggleCard
                platformCard
                repeatCard
                commentsCard
                if let hint = scroller.setupHint { noticeCard(icon: "wrench.and.screwdriver", color: .orange, title: "브라우저 설정이 한 번 필요해요", text: hint) }
                if let problem = scroller.problem { noticeCard(icon: "exclamationmark.triangle", color: .red, title: "지금은 동작하지 않아요", text: problem) }
                statusCard
                tipCard
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .onAppear { scroller.refreshBrowsers() }
    }

    private var header: some View {
        HStack {
            Text("자동 스크롤")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("YouTube 쇼츠 · Instagram 릴스")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.chipFill(scheme)))
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    private var toggleCard: some View {
        ActionRow(icon: "play.square.stack", title: "쇼츠 자동 넘기기",
                  subtitle: scroller.isEnabled
                    ? "한 편이 끝나면 브라우저 쇼츠 탭을 다음 편으로 넘겨요. 다른 창에서 일해도 계속 동작해요."
                    : "켜면 브라우저의 쇼츠 탭을 지켜보다가 한 편이 끝날 때 다음 편으로 넘겨요.") {
            Toggle("", isOn: Binding(get: { scroller.isEnabled }, set: { scroller.setEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var repeatCard: some View {
        ActionRow(icon: "repeat", title: "반복 횟수",
                  subtitle: scroller.repeatCount == 1 ? "한 번 다 보면 바로 넘겨요." : "같은 쇼츠를 \(scroller.repeatCount)번 본 뒤에 넘겨요.") {
            HStack(spacing: 6) {
                Text("\(scroller.repeatCount)번")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Stepper("", value: Binding(get: { scroller.repeatCount }, set: { scroller.setRepeatCount($0) }),
                        in: AutoScroller.repeatRange)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    private var platformCard: some View {
        VStack(spacing: 0) {
            ForEach(ScrollPlatform.allCases) { platform in
                HStack(spacing: 12) {
                    Image(systemName: platform.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(platform.title).font(.system(size: 13, weight: .semibold))
                        Text(platform == .youtubeShorts ? "youtube.com/shorts 탭" : "instagram.com/reels 탭 · 버튼 → 스크롤 → 키 순으로 넘겨요")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { scroller.platforms.contains(platform) }, set: { scroller.setPlatform(platform, enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if platform != ScrollPlatform.allCases.last { Divider().padding(.leading, 54) }
            }
        }
        .card()
    }

    private var commentsCard: some View {
        ActionRow(icon: "text.bubble", title: "열면 댓글도 항상 열기",
                  subtitle: scroller.autoOpenComments
                    ? "새 쇼츠·릴스로 넘어갈 때마다 댓글 패널이 닫혀 있으면 자동으로 열어요."
                    : "켜면 쇼츠·릴스마다 댓글 패널을 자동으로 펼쳐요.") {
            Toggle("", isOn: Binding(get: { scroller.autoOpenComments }, set: { scroller.setAutoOpenComments($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func noticeCard(icon: String, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("상태")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(browserLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !scroller.isEnabled {
                Text("꺼져 있어요")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else if scroller.tabs.isEmpty {
                Text("열려 있는 쇼츠·릴스 탭을 찾는 중… youtube.com/shorts 또는 instagram.com/reels 탭이 있으면 자동으로 붙어요")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(scroller.tabs) { tab in
                    tabRow(tab)
                }
            }
            if scroller.advancedThisSession > 0 {
                Text("이번 세션에 \(scroller.advancedThisSession)편 넘겼어요")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private var browserLine: String {
        let names = scroller.runningBrowsers.map(\.name)
        return names.isEmpty ? "브라우저 없음" : names.joined(separator: " · ") + " 실행 중"
    }

    private func tabRow(_ tab: ShortsTabStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: tab.platform.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(tab.platform.title)
                Text(tab.title.isEmpty ? tab.shortsID : tab.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !tab.method.isEmpty {
                    Text(tab.method)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("마지막으로 넘긴 방식")
                }
                Spacer(minLength: 8)
                if scroller.autoOpenComments {
                    Image(systemName: tab.commentsOpen ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 10))
                        .foregroundStyle(tab.commentsOpen ? Theme.accent : Color.secondary)
                        .help(tab.commentsOpen ? "댓글 열림" : "댓글 여는 중")
                }
                Text("\(min(tab.plays + 1, scroller.repeatCount))/\(scroller.repeatCount)번째")
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                UsageBar(fraction: tab.duration > 0 ? tab.time / tab.duration : 0, color: Theme.accent, height: 5)
                Text(timeLabel(tab))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func timeLabel(_ tab: ShortsTabStatus) -> String {
        guard tab.duration > 0 else { return "--:--" }
        func f(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
        return "\(f(tab.time)) / \(f(tab.duration))"
    }

    private var tipCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.draw")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("손으로 넘겨도 괜찮아요")
                    .font(.system(size: 13, weight: .semibold))
                Text("다시 보고 싶으면 위로 올리면 돼요. 그 편이 다시 끝나면 또 넘겨요. 처음 켤 때 macOS가 브라우저 제어 권한을 물어보면 허용해 주세요. Firefox는 지원하지 않아요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }
}
