import AppKit
import SwiftUI

/// Status + install help for the Zen/Firefox bridge extension.
struct BrowserBridgeCard: View {
    var bridge: BrowserBridge
    @Environment(\.colorScheme) private var scheme
    @State private var showHelp = false

    private var zenRunning: Bool { ShortsBrowser.zen.isRunning }
    private var firefoxRunning: Bool { ShortsBrowser.firefox.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: bridge.isConnected ? "link.circle.fill" : "link.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(bridge.isConnected ? Color.green : Color.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bridge.isConnected ? "Zen · Firefox 연결됨 (\(bridge.connectedNames))" : "Zen · Firefox 연결")
                        .font(.system(size: 12, weight: .semibold))
                    Text(statusText).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(showHelp ? "닫기" : "확장 설치") { withAnimation(.snappy(duration: 0.2)) { showHelp.toggle() } }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if showHelp {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text("영구 설치 (권장)").font(.system(size: 11, weight: .semibold))
                    step("1", "Zen 주소창에 about:config → xpinstall.signatures.required 를 false 로 (Zen은 서명 없는 확장을 허용해요)")
                    step("2", "아래 '.xpi 파일 보기'로 나온 ATFM-Bridge.xpi 를 Zen 창에 끌어다 놓고 '추가'")
                    Text("임시 설치 (브라우저를 껐다 켜면 사라짐)").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
                    step("1", "about:debugging#/runtime/this-firefox → '임시 부가 기능 로드…' → 아래 '확장 폴더 보기'의 manifest.json 선택")
                    Text("설치되면 몇 초 안에 위 상태가 '연결됨'으로 바뀌어요. 통신은 이 Mac 안(127.0.0.1:\(BrowserBridge.port))에서만 이뤄져요.")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    HStack(spacing: 8) {
                        Button(".xpi 파일 보기") { if let url = BrowserBridge.xpi { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                        Button("확장 폴더 보기") { if let url = BrowserBridge.extensionFolder { NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent("manifest.json")]) } }
                        if zenRunning || firefoxRunning {
                            Button("about:debugging 열기") { openInGecko("about:debugging#/runtime/this-firefox") }
                            Button("about:config 열기") { openInGecko("about:config") }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .card()
    }

    private var statusText: String {
        if let error = bridge.lastError { return error }
        if bridge.isConnected { return "쇼츠·릴스 자동 스크롤, 채팅 프라이버시, 플레이리스트 분석이 이 브라우저에서도 동작해요" }
        if zenRunning || firefoxRunning { return "\(zenRunning ? "Zen" : "Firefox")이 실행 중이지만 ATFM Bridge 확장이 아직 연결되지 않았어요" }
        return "Zen·Firefox는 Apple 이벤트를 지원하지 않아 작은 확장(ATFM Bridge)이 다리 역할을 해요"
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent).frame(width: 12, alignment: .trailing)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openInGecko(_ url: String) {
        let bundle = zenRunning ? ShortsBrowser.zen.rawValue : ShortsBrowser.firefox.rawValue
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [url]
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}
