import SwiftUI

struct SystemView: View {
    @Bindable var monitor: SystemMonitor
    @State private var showAllApps = false
    @State private var showCores = false
    @Environment(\.colorScheme) private var scheme

    private var hasTemperature: Bool {
        monitor.cpuTemperature != nil || monitor.gpuTemperature != nil || monitor.battery?.temperatureC != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if hasTemperature { temperatureCard }
                usageCard
                appsCard
                memoryCard
                uptimeRow
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("시스템")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(monitor.chipName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Temperature

    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "온도")
            HStack(spacing: 8) {
                if let t = monitor.cpuTemperature {
                    StatTile(title: "CPU", systemImage: "cpu", value: Format.celsius(t))
                }
                if let t = monitor.gpuTemperature {
                    StatTile(title: "GPU", systemImage: "memorychip", value: Format.celsius(t))
                }
                if let t = monitor.battery?.temperatureC {
                    StatTile(title: "배터리", systemImage: "battery.100", value: Format.celsius(t))
                }
            }
        }
        .padding(12)
        .card()
    }

    // MARK: Usage

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "하드웨어 사용량")
            cpuRow
            if showCores { coreGrid }
            if let gpu = monitor.gpu {
                MetricRow(title: "GPU", valueText: Format.percent(gpu.device), fraction: gpu.device / 100,
                          color: .teal, history: monitor.gpuHistory)
            }
            if let battery = monitor.battery {
                MetricRow(title: "배터리", valueText: "\(battery.percent)%", fraction: Double(battery.percent) / 100,
                          color: batteryColor(battery), history: [], subtitle: battery.statusText)
            }
        }
        .padding(12)
        .card()
    }

    private var cpuRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetricRow(title: "CPU", valueText: Format.percent(monitor.cpuPercent), fraction: monitor.cpuPercent / 100,
                      color: .blue, history: monitor.cpuHistory)
            Button {
                withAnimation(.snappy(duration: 0.2)) { showCores.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCores ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("코어별 · P코어 \(monitor.performanceCores) · E코어 \(monitor.efficiencyCores)")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var coreGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(monitor.perCore.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 2) {
                    UsageBar(fraction: value / 100, color: .blue, height: 5)
                    Text("\(index + 1)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 2)
    }

    private func batteryColor(_ battery: BatteryStats) -> Color {
        if battery.percent <= 20 && !battery.onACPower { return .red }
        return .green
    }

    // MARK: Apps

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "앱별 사용량")
                Spacer()
                sortPicker
            }
            appRows
            if monitor.sortedApps.count > 8 {
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

    private var sortPicker: some View {
        Picker("", selection: $monitor.sortMode) {
            ForEach(AppSortMode.allCases) { mode in
                if mode != .energy || monitor.hasEnergyData {
                    Text(mode.title).tag(mode)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: monitor.hasEnergyData ? 170 : 120)
    }

    @ViewBuilder
    private var appRows: some View {
        let apps = Array(monitor.sortedApps.prefix(showAllApps ? 20 : 8))
        if apps.isEmpty {
            Text("측정 중…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            let peak = max(0.0001, apps.map(metric).max() ?? 1)
            VStack(spacing: 0) {
                ForEach(apps) { app in
                    AppUsageRow(bundlePath: app.bundlePath, name: app.name, value: valueText(app),
                                detail: detailText(app), fraction: metric(app) / peak, color: sortColor)
                }
            }
        }
    }

    private var sortColor: Color {
        switch monitor.sortMode {
        case .cpu: return .blue
        case .memory: return .purple
        case .energy: return .orange
        }
    }

    private func metric(_ app: AppUsage) -> Double {
        switch monitor.sortMode {
        case .cpu: return app.cpuPercent
        case .memory: return Double(app.memoryBytes)
        case .energy: return app.energyMilliwatts
        }
    }

    private func valueText(_ app: AppUsage) -> String {
        switch monitor.sortMode {
        case .cpu: return Format.percent(app.cpuPercent, decimals: 1)
        case .memory: return Format.memory(app.memoryBytes)
        case .energy: return Format.milliwatts(app.energyMilliwatts)
        }
    }

    private func detailText(_ app: AppUsage) -> String {
        let processes = app.processCount == 1 ? "프로세스 1개" : "프로세스 \(app.processCount)개"
        switch monitor.sortMode {
        case .cpu: return processes + " · " + Format.memory(app.memoryBytes)
        case .memory: return processes + " · CPU " + Format.percent(app.cpuPercent, decimals: 1)
        case .energy: return processes + " · CPU " + Format.percent(app.cpuPercent, decimals: 1)
        }
    }

    // MARK: Memory

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "메모리")
                Spacer()
                if let memory = monitor.memory { pressureBadge(memory) }
            }
            if let memory = monitor.memory {
                memoryDetails(memory)
            }
        }
        .padding(12)
        .card()
    }

    private func pressureBadge(_ memory: MemoryStats) -> some View {
        let color: Color = memory.pressureLevel >= 4 ? .red : (memory.pressureLevel >= 2 ? .orange : .green)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("압력 " + memory.pressureLabel).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private func memoryDetails(_ memory: MemoryStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.memory(memory.used))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("/ " + Format.memory(memory.total))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(memory.usedFraction * 100))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            stackedBar(memory)
            HStack(spacing: 12) {
                legend("앱", Format.memory(memory.appMemory), .purple)
                legend("사용 중", Format.memory(memory.wired), .indigo)
                legend("압축", Format.memory(memory.compressed), .pink)
            }
            HStack(spacing: 12) {
                legend("캐시된 파일", Format.memory(memory.cachedFiles), .gray)
                legend("스왑", Format.memory(memory.swapUsed), .orange)
            }
            Sparkline(values: monitor.memoryHistory, maxValue: 100, color: .purple)
                .frame(height: 22)
        }
    }

    private func stackedBar(_ memory: MemoryStats) -> some View {
        GeometryReader { geo in
            let total = max(1, Double(memory.total))
            HStack(spacing: 1) {
                Rectangle().fill(Color.purple).frame(width: geo.size.width * CGFloat(Double(memory.appMemory) / total))
                Rectangle().fill(Color.indigo).frame(width: geo.size.width * CGFloat(Double(memory.wired) / total))
                Rectangle().fill(Color.pink).frame(width: geo.size.width * CGFloat(Double(memory.compressed) / total))
                Rectangle().fill(Color.primary.opacity(0.08))
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }

    private func legend(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
    }

    // MARK: Uptime

    private var uptimeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text("가동 시간").font(.system(size: 13))
            Text(UptimeProbe.format(monitor.uptime)).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(12)
        .card()
    }
}
