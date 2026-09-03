import SwiftUI

struct NetworkView: View {
    @Bindable var monitor: NetworkMonitor
    @Bindable var tester: SpeedTester
    @State private var showAllApps = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                speedCard
                appsCard
                testCard
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("네트워크")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(interfaceSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    private var interfaceSummary: String {
        var parts: [String] = []
        if let kind = monitor.interfaceKind { parts.append(kind) }
        if let name = monitor.primaryInterface { parts.append(name) }
        if let ip = monitor.localIPv4 { parts.append(ip) }
        return parts.isEmpty ? "연결 없음" : parts.joined(separator: " · ")
    }

    // MARK: Live speed

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "현재 속도")
            HStack(spacing: 12) {
                speedColumn(title: "다운로드", symbol: "arrow.down", rate: monitor.downloadRate,
                            history: monitor.downloadHistory, color: .blue)
                speedColumn(title: "업로드", symbol: "arrow.up", rate: monitor.uploadRate,
                            history: monitor.uploadHistory, color: .green)
            }
            Text("이번 세션 · ↓ \(Format.bytes(monitor.sessionDownloaded)) · ↑ \(Format.bytes(monitor.sessionUploaded))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .card()
    }

    private func speedColumn(title: String, symbol: String, rate: Double, history: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(color)
            Text(Format.rate(rate))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Sparkline(values: history, color: color)
                .frame(height: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Per-app

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "앱별 사용량")
                Spacer()
                Text("2초마다 갱신").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            appRows
            if monitor.apps.count > 8 {
                Button(showAllApps ? "간단히 보기" : "더 보기") {
                    withAnimation(.snappy(duration: 0.2)) { showAllApps.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .card()
    }

    @ViewBuilder
    private var appRows: some View {
        let apps = Array(monitor.apps.prefix(showAllApps ? 20 : 8))
        if !monitor.perAppAvailable {
            Text("앱별 사용량을 가져오지 못했어요 (nettop 실행 실패)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else if apps.isEmpty {
            Text("측정 중… 트래픽이 생기면 여기에 표시돼요")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            let peak = max(1, apps.map(\.totalRate).max() ?? 1)
            VStack(spacing: 0) {
                ForEach(apps) { app in
                    networkRow(app, peak: peak)
                }
            }
        }
    }

    private func networkRow(_ app: AppNetworkUsage, peak: Double) -> some View {
        HStack(spacing: 10) {
            ProcessIcon(bundlePath: app.bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("↓ " + Format.rate(app.inRate))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.blue)
                    Text("↑ " + Format.rate(app.outRate))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.green)
                }
                UsageBar(fraction: app.totalRate / peak, color: .blue, height: 5)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Speed test

    private var testCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "속도 측정")
                Spacer()
                Button {
                    tester.run()
                } label: {
                    Label(tester.isRunning ? "측정 중" : "측정 시작", systemImage: "gauge.with.needle")
                }
                .controlSize(.small)
                .disabled(tester.isRunning)
            }
            if tester.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tester.phase.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if tester.liveMbps > 0 {
                        Text(Format.mbps(tester.liveMbps) + " Mbps")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                }
            } else if case .failed(let message) = tester.phase {
                Text(message).font(.system(size: 12)).foregroundStyle(.red)
            }
            if tester.pingMs != nil || tester.downloadMbps != nil || tester.uploadMbps != nil {
                HStack(spacing: 8) {
                    StatTile(title: "다운로드", systemImage: "arrow.down", value: tester.downloadMbps.map { Format.mbps($0) } ?? "–")
                    StatTile(title: "업로드", systemImage: "arrow.up", value: tester.uploadMbps.map { Format.mbps($0) } ?? "–")
                    StatTile(title: "지연", systemImage: "timer", value: tester.pingMs.map { String(format: "%.0f", $0) } ?? "–")
                }
                Text("Mbps · Mbps · ms — Cloudflare 서버 기준")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if !tester.isRunning {
                Text("Cloudflare 서버로 약 20초간 다운로드/업로드 속도와 지연 시간을 측정합니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .card()
    }
}
