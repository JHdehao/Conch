import Charts
import SwiftUI

/// Identifies one opening of the status page (for `.sheet(item:)`).
struct MonitorRequest: Identifiable {
    let id = UUID()
    let target: ConnectionTarget
}

/// CPU, memory and disk rings, live charts, top processes and partitions of a server.
/// Half height over the terminal on iPhone; the rings and CPU chart fit the top half.
struct ServerMonitorView: View {
    let target: ConnectionTarget
    @State private var monitor: ServerMonitor
    @State private var range = TimeRange.oneMinute
    @State private var sortByMemory = false
    @State private var stopping: ServerMonitor.Process?
    @State private var stopError: String?
    @CurrentTheme private var theme
    @Environment(\.dismiss) private var dismiss

    init(target: ConnectionTarget) {
        self.target = target
        _monitor = State(initialValue: ServerMonitor(connection: AgentHub.shared.connection(for: target)))
    }

    enum TimeRange: Int, CaseIterable, Identifiable {
        case oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900
        var id: Int { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .oneMinute: "1 分钟"
            case .fiveMinutes: "5 分钟"
            case .fifteenMinutes: "15 分钟"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if monitor.hasData {
                    ScrollView { content.padding(16) }
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .conchCanvas()
            .navigationTitle(target.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .agentConnectionPrompts(monitor.connection)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .confirmationDialog(stopTitle, isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible) {
            if let process = stopping {
                Button("结束进程", role: .destructive) { stop(process) }
            }
        } message: {
            Text("发送 SIGTERM，让它自行退出。")
        }
        .alert("没能结束进程", isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(verbatim: stopError ?? "")
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 560, idealHeight: 760)
        #endif
    }

    @ViewBuilder
    private var placeholder: some View {
        switch monitor.phase {
        case .unsupported(let system):
            ContentUnavailableView {
                Label("暂不支持这台服务器", systemImage: "gauge.with.dots.needle.0percent")
            } description: {
                Text("服务器状态目前只支持 Linux，这台是 \(system)。")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("读不到服务器状态", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("重试") { monitor.retry() }
            }
        case .connecting, .live:
            ProgressView("正在读取服务器状态…")
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            header
            rings
            Picker("时间范围", selection: $range) {
                ForEach(TimeRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            cpuCard
            networkCard
            processCard
            if !monitor.partitions.isEmpty { partitionCard }
            Text("每 2 秒更新 · 通过 SSH 读取，服务器上不用装任何东西")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    // MARK: - Sections

    private var header: some View {
        Card(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(monitor.phase == .live ? "在线" : "重新连接中…")
                Text(verbatim: "·").foregroundStyle(.secondary)
                Text("已运行 \(Self.duration(monitor.uptime))").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Text(verbatim: [monitor.system, monitor.kernel.isEmpty ? "" : String(localized: "内核 \(monitor.kernel)"),
                            String(localized: "\(monitor.cores) 核"), String(localized: "\(Self.bytes(monitor.memoryTotal)) 内存")]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if monitor.load.count == 3 {
                HStack(spacing: 8) {
                    Text("负载").foregroundStyle(.secondary)
                    ForEach(Array(monitor.load.enumerated()), id: \.offset) { index, value in
                        Text(value, format: .number.precision(.fractionLength(2)))
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                    }
                }
                .font(.footnote.monospacedDigit())
            }
        }
    }

    private var rings: some View {
        HStack(alignment: .top) {
            UsageRing(fraction: monitor.cpu, label: "CPU", detail: Text("\(monitor.cores) 核"), color: tint(monitor.cpu))
            Spacer(minLength: 0)
            UsageRing(fraction: monitor.memoryFraction, label: "内存",
                      detail: Text(verbatim: "\(Self.bytes(monitor.memoryUsed)) / \(Self.bytes(monitor.memoryTotal))"),
                      color: tint(monitor.memoryFraction))
            Spacer(minLength: 0)
            if let disk = monitor.mainPartition {
                UsageRing(fraction: disk.fraction, label: "磁盘",
                          detail: Text(verbatim: "\(disk.mount) · \(Self.bytes(disk.used)) / \(Self.bytes(disk.size))"),
                          color: tint(disk.fraction))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .background(theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var cpuCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(.subheadline.weight(.semibold))
                Spacer()
                Text("用户 \(Self.percent(monitor.cpuUser)) · 系统 \(Self.percent(monitor.cpuSystem)) · iowait \(Self.percent(monitor.cpuIOWait))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Chart(recent(monitor.cpuHistory)) { sample in
                AreaMark(x: .value("时间", sample.date), y: .value("CPU", sample.value))
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                LineMark(x: .value("时间", sample.date), y: .value("CPU", sample.value))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            .chartYScale(domain: 0...1)
            .chartXScale(domain: Date.now.addingTimeInterval(-Double(range.rawValue))...Date.now)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0.25, 0.5, 0.75]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                }
            }
            .frame(height: 110)
            if !monitor.coreUsage.isEmpty {
                Text("每核占用").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(monitor.coreUsage.count, 8)), spacing: 6) {
                    ForEach(Array(monitor.coreUsage.enumerated()), id: \.offset) { _, value in
                        CoreBar(fraction: value, color: tint(value), track: theme.chrome.groupedColor)
                    }
                }
            }
        }
    }

    private var networkCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("网络").font(.subheadline.weight(.semibold))
                Spacer()
                Text(verbatim: monitor.networkInterface).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                legend(color: downloadColor, label: "下载", value: Self.rate(monitor.receiveRate))
                legend(color: uploadColor, label: "上传", value: Self.rate(monitor.sendRate))
            }
            Chart {
                ForEach(recent(monitor.receiveHistory)) { sample in
                    LineMark(x: .value("时间", sample.date), y: .value("速率", sample.value), series: .value("方向", "rx"))
                        .foregroundStyle(downloadColor)
                }
                ForEach(recent(monitor.sendHistory)) { sample in
                    LineMark(x: .value("时间", sample.date), y: .value("速率", sample.value), series: .value("方向", "tx"))
                        .foregroundStyle(uploadColor)
                }
            }
            .chartXScale(domain: Date.now.addingTimeInterval(-Double(range.rawValue))...Date.now)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 70)
            Divider()
            HStack {
                Text("磁盘读写").font(.subheadline.weight(.semibold))
                Spacer()
                Text("读 \(Self.rate(monitor.readRate))  写 \(Self.rate(monitor.writeRate))")
                    .font(.subheadline.monospacedDigit())
            }
        }
    }

    private var processCard: some View {
        Card {
            HStack {
                Text("进程").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("排序", selection: $sortByMemory) {
                    Text(verbatim: "CPU").tag(false)
                    Text("内存").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            let processes = Array((sortByMemory ? monitor.byMemory : monitor.byCPU).prefix(8))
            let maxCPU = max(processes.map(\.cpu).max() ?? 0, 1)
            VStack(spacing: 0) {
                ForEach(processes) { process in
                    Divider()
                    ProcessRow(process: process, barFraction: process.cpu / maxCPU, track: theme.chrome.groupedColor)
                        .contextMenu {
                            Button(role: .destructive) { stopping = process } label: {
                                Label("结束进程", systemImage: "xmark.octagon")
                            }
                        }
                }
            }
            Text("长按一行可以结束进程").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var partitionCard: some View {
        Card {
            Text("分区").font(.subheadline.weight(.semibold))
            ForEach(monitor.partitions) { partition in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: partition.mount).font(.subheadline.monospaced())
                        Spacer()
                        Text(verbatim: "\(Self.bytes(partition.used)) / \(Self.bytes(partition.size))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressBar(fraction: partition.fraction, color: tint(partition.fraction), track: theme.chrome.groupedColor)
                }
            }
        }
    }

    private func legend(color: Color, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - Helpers

    private func recent(_ samples: [ServerMonitor.Sample]) -> [ServerMonitor.Sample] {
        let cutoff = Date.now.addingTimeInterval(-Double(range.rawValue))
        return samples.filter { $0.date >= cutoff }
    }

    private func stop(_ process: ServerMonitor.Process) {
        stopping = nil
        Task { stopError = await monitor.terminate(process) }
    }

    private var stopTitle: String {
        guard let process = stopping else { return "" }
        return String(localized: "结束 \(process.name)（PID \(process.pid)）？")
    }

    private var statusColor: Color { monitor.phase == .live ? ansi(2) : ansi(3) }
    private var downloadColor: Color { ansi(4) }
    private var uploadColor: Color { ansi(3) }

    /// The accent normally, the theme's yellow from 70% and its red from 90%.
    private func tint(_ fraction: Double) -> Color {
        fraction >= 0.9 ? ansi(1) : fraction >= 0.7 ? ansi(3) : .accentColor
    }

    private func ansi(_ index: Int) -> Color { TerminalTheme.color(theme.ansi[index]) }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter.string(from: seconds) ?? ""
    }
}

// MARK: - Pieces

private struct Card<Content: View>: View {
    let spacing: CGFloat
    let content: Content
    @CurrentTheme private var theme

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The context ring's look, large: thin track, round cap, value in the middle.
private struct UsageRing: View {
    let fraction: Double
    let label: LocalizedStringKey
    let detail: Text
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(min(fraction, 1), 0.01))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(ServerMonitorView.percent(fraction))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(width: 84, height: 84)
            .animation(.snappy(duration: 0.4), value: fraction)
            Text(label).font(.subheadline.weight(.medium))
            detail
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 110)
        .accessibilityElement(children: .combine)
    }
}

private struct CoreBar: View {
    let fraction: Double
    let color: Color
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(track)
                RoundedRectangle(cornerRadius: 4).fill(color)
                    .frame(height: max(proxy.size.height * min(fraction, 1), 2))
            }
        }
        .frame(height: 28)
        .animation(.snappy(duration: 0.4), value: fraction)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let color: Color
    let track: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

private struct ProcessRow: View {
    let process: ServerMonitor.Process
    let barFraction: Double
    let track: Color

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: process.name).font(.subheadline).lineLimit(1)
                Text(verbatim: process.user.isEmpty ? "PID \(process.pid)" : "\(process.user) · PID \(process.pid)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: String(format: "%.1f%%", process.cpu)).font(.subheadline.monospacedDigit())
                ProgressBar(fraction: barFraction, color: .accentColor, track: track, height: 3).frame(width: 56)
            }
            Text(verbatim: ServerMonitorView.bytes(process.memory))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
