import AppKit
import SwiftUI

/// A fake messenger window (sample data only) used to develop and screenshot chat privacy mode.
@MainActor
enum PrivacySampleWindow {
    static let titleKeyword = "메신저 샘플"

    static func target() -> PrivacyTarget {
        PrivacyTarget(id: "debug:self", bundleID: Bundle.main.bundleIdentifier ?? "com.geonhee.atfm", name: "ATFM 샘플", nameHint: nil,
                      titleKeyword: titleKeyword, urlKeywords: nil, excludedTitles: nil, topInset: 0, composerHeight: 96, enabled: true, isPreset: false)
    }

    @discardableResult
    static func show(at origin: NSPoint? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ATFM 팀 · \(titleKeyword)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SampleChatView())
        if let origin { window.setFrameOrigin(origin) } else { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

private struct SampleChatView: View {
    private struct Line: Identifiable {
        let id = UUID()
        let mine: Bool
        let text: String
        let time: String
    }

    private let lines: [Line] = [
        Line(mine: false, text: "오늘 회의 3시로 옮겨도 될까요?", time: "오후 1:02"),
        Line(mine: true, text: "네 괜찮아요 👍 회의실 B로 잡을게요", time: "오후 1:03"),
        Line(mine: false, text: "발표 자료는 어제 공유한 폴더에 올려뒀어요. 2페이지 그래프만 한 번 봐주세요", time: "오후 1:05"),
        Line(mine: true, text: "확인했어요. 색만 조금 손보면 될 것 같아요", time: "오후 1:09"),
        Line(mine: false, text: "점심은 뭐 먹을까요", time: "오후 1:10"),
        Line(mine: true, text: "저 김치찌개요 🍲", time: "오후 1:10"),
        Line(mine: false, text: "좋아요 그럼 12시 반에 로비에서 봐요", time: "오후 1:11"),
        Line(mine: true, text: "넵!", time: "오후 1:11"),
        Line(mine: false, text: "아 그리고 배포는 목요일 저녁으로 미뤄졌대요", time: "오후 1:20"),
        Line(mine: true, text: "오 다행이다 그럼 테스트 하루 더 할 수 있겠네요", time: "오후 1:21"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Color.orange.opacity(0.7)).frame(width: 28, height: 28)
                    .overlay(Text("A").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text("ATFM 팀").font(.system(size: 13, weight: .semibold))
                    Text("4명").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        Text("2026년 9월 18일 금요일")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .padding(.top, 8)
                        ForEach(lines) { line in
                            HStack(alignment: .bottom, spacing: 6) {
                                if line.mine { Spacer(minLength: 60); Text(line.time).font(.system(size: 9)).foregroundStyle(.secondary) }
                                Text(line.text)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(line.mine ? Color.yellow.opacity(0.75) : Color.primary.opacity(0.07)))
                                if !line.mine { Text(line.time).font(.system(size: 9)).foregroundStyle(.secondary); Spacer(minLength: 60) }
                            }
                            .padding(.horizontal, 14)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            VStack(spacing: 6) {
                HStack(alignment: .top) {
                    Text("지금 입력 중인 메시지예요. 이 부분은 가려지지 않아요")
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 10)
                HStack(spacing: 12) {
                    Image(systemName: "face.smiling"); Image(systemName: "paperclip"); Image(systemName: "photo")
                    Spacer()
                    Text("전송").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.yellow.opacity(0.8)))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 10)
            }
            .frame(height: 96)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
