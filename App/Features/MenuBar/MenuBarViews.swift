import Charts
import MetricsKit
import SwiftUI

/// The text in the menu bar: the readouts chosen in Settings › Menu bar, or the KeelMac mark.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Preferences.Key.menuBarItems) private var itemsRaw = "cpu,memory,temperature"

    var body: some View {
        let items = MenuBarItem.decode(itemsRaw)
        Group {
            if items.isEmpty || model.metrics.latest == nil {
                Image(systemName: "gauge.with.dots.needle.33percent")
            } else {
                Text(verbatim: items.compactMap(readout).joined(separator: "  "))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("KeelMac")
        .task {
            model.start()
            // A launch opens the main window, even if it was closed when KeelMac last quit (window restoration).
            if !CommandLine.arguments.contains("-menuBarOnly"), !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) {
                openWindow(id: "main")
            }
        }
    }

    private func readout(_ item: MenuBarItem) -> String? {
        let m = model.metrics
        guard let s = m.latest else { return nil }
        switch item {
        case .cpu:
            return s.cpu.map { "CPU \(Format.percent($0.total))" }
        case .memory:
            return s.memory.map { "Mem \(Format.percent(Double($0.usedBytes) / Double(max($0.totalBytes, 1))))" }
        case .disk:
            return s.disk.map { "SSD \(Format.bytes($0.availableBytes))" }
        case .network:
            return s.network.map { "\(Format.rate($0.bytesInPerSecond)) / \(Format.rate($0.bytesOutPerSecond))" }
        case .battery:
            return m.battery.flatMap { $0.isPresent ? $0.chargePercent.map { "\($0)%" } : nil }
        case .temperature:
            return m.temperature.map { Format.temperature($0) }
        }
    }
}

/// S4: menu bar popover.
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var chart: ChartKind = .cpu
    @State private var sort: ProcessSort = .cpu

    var body: some View {
        let m = model.metrics
        VStack(alignment: .leading, spacing: 16) {
            Readouts(metrics: m)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Last 60 minutes").fontWeight(.semibold)
                    Spacer()
                    Picker("Chart", selection: $chart) {
                        Text("CPU").tag(ChartKind.cpu)
                        Text("Memory").tag(ChartKind.memory)
                    }
                    .pickerStyle(.segmented).tint(.kmControlAccent)
                    .labelsHidden()
                    .fixedSize()
                }
                HistoryChart(points: m.history.elements, kind: chart)
                    .frame(height: 80)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Top processes").fontWeight(.semibold)
                    Spacer()
                    Picker("Sort processes by", selection: $sort) {
                        Text("CPU").tag(ProcessSort.cpu)
                        Text("Memory").tag(ProcessSort.memory)
                    }
                    .pickerStyle(.segmented).tint(.kmControlAccent)
                    .labelsHidden()
                    .fixedSize()
                }
                if m.processes.isEmpty {
                    Text("Measuring…").foregroundStyle(.kmFgMuted).padding(.vertical, 6)
                } else {
                    ForEach(sort.top(m.processes, count: 5)) { p in
                        HStack {
                            Text(verbatim: p.name).lineLimit(1)
                            Spacer()
                            Text(sort == .cpu ? Format.percent(p.cpuPercent / 100, digits: 1) : Format.memory(p.memoryBytes)).tabular()
                            QuitButton(process: p, compact: true)
                        }
                        .frame(minHeight: 32)
                    }
                }
            }
            if let b = m.battery, b.isPresent {
                Divider()
                BatteryLine(battery: b).font(.callout).foregroundStyle(.kmFgMuted)
            }
            Divider()
            HStack {
                Button("Open KeelMac") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
                .foregroundStyle(.kmAccentText)
                Spacer()
                SettingsLink { Text("Settings…") }.buttonStyle(.borderless)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(.kmBg)
        .foregroundStyle(.kmFg)
        .detailedMetrics(m)
    }
}

private struct Readouts: View {
    let metrics: MetricsMonitor

    var body: some View {
        let s = metrics.latest
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 16) {
            GridRow {
                cell("CPU", s?.cpu.map { Text(Format.percent($0.total)) })
                cell("Memory", s?.memory.map { Text($0.pressure.label) })
                cell("Disk free", s?.disk.map { Text(Format.bytes($0.availableBytes)) })
            }
            GridRow {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Network").font(.caption).foregroundStyle(.kmFgMuted)
                    if let n = s?.network {
                        Text("In \(Format.rate(n.bytesInPerSecond))").fontWeight(.semibold)
                        Text("Out \(Format.rate(n.bytesOutPerSecond))").font(.caption).foregroundStyle(.kmFgMuted)
                    } else {
                        Text("Measuring…").foregroundStyle(.kmFgMuted)
                    }
                }
                cell("Battery", metrics.battery.flatMap { b in b.isPresent ? b.chargePercent.map { Text("\($0)%") } : Text("No battery") })
                cell("Temperature", metrics.temperature.map { Text(Format.temperature($0)) } ?? (s == nil ? nil : Text("Unavailable")))
            }
        }
        .tabular()
    }

    private func cell(_ title: LocalizedStringKey, _ value: Text?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.kmFgMuted)
            (value ?? Text("Measuring…").foregroundStyle(.kmFgMuted))
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ChartKind: Hashable { case cpu, memory, network, temperature }

enum ProcessSort: Hashable {
    case cpu, memory
    func top(_ list: [ProcessSample], count: Int) -> [ProcessSample] {
        switch self {
        case .cpu: Array(list.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(count))
        case .memory: Array(list.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(count))
        }
    }
}

/// A single-series line in the accent colour over the last hour.
struct HistoryChart: View {
    let points: [HistoryPoint]
    let kind: ChartKind

    var body: some View {
        Chart(points) { p in
            if let v = value(p) {
                LineMark(x: .value("Time", p.date), y: .value("Value", v))
                    .foregroundStyle(.kmAccent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: Date.now.addingTimeInterval(-3600)...Date.now)
        .chartYScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
                AxisGridLine().foregroundStyle(.kmBorder)
            }
        }
        .accessibilityLabel(accessibility)
    }

    private func value(_ p: HistoryPoint) -> Double? {
        switch kind {
        case .cpu: p.cpu
        case .memory: p.memoryUsedFraction
        case .network: p.netIn
        case .temperature: p.temperature
        }
    }

    private var domain: ClosedRange<Double> {
        switch kind {
        case .cpu, .memory: 0...1
        case .network: 0...max(1, points.compactMap(\.netIn).max() ?? 1)
        case .temperature: 20...max(60, (points.compactMap(\.temperature).max() ?? 60) + 5)
        }
    }

    private var accessibility: Text {
        let values = points.compactMap(value)
        guard let lo = values.min(), let hi = values.max() else { return Text("No data yet") }
        switch kind {
        case .cpu, .memory: return Text("Last hour, between \(Format.percent(lo)) and \(Format.percent(hi))")
        case .network: return Text("Last hour, up to \(Format.rate(hi))")
        case .temperature: return Text("Last hour, between \(Format.temperature(lo)) and \(Format.temperature(hi))")
        }
    }
}

struct BatteryLine: View {
    let battery: BatteryInfo
    var body: some View {
        HStack(spacing: 4) {
            if let cap = battery.maxCapacityPercent { Text("Battery \(Format.percent(cap / 100)) capacity") }
            if let cycles = battery.cycleCount { Text(verbatim: ",") ; Text("\(cycles) cycles") }
            if let c = battery.condition { Text(verbatim: ","); Text(LocalizedStringKey(c)) }
        }
        .tabular()
    }
}

/// Quit for apps, SIGTERM (with confirmation) for other processes of this user; nothing for system processes.
struct QuitButton: View {
    let process: ProcessSample
    var compact = false
    @State private var confirm = false

    var body: some View {
        Group {
            if !process.isOwnedByCurrentUser || process.id == ProcessInfo.processInfo.processIdentifier {
                Text("System").font(.caption).foregroundStyle(.kmFgMuted).frame(minWidth: 44)
            } else if let app = NSRunningApplication(processIdentifier: process.id), app.activationPolicy != .prohibited {
                Button { app.terminate() } label: { Text("Quit app") }
                    .controlSize(compact ? .small : .regular)
            } else {
                Button("Quit…") { confirm = true }
                    .controlSize(compact ? .small : .regular)
            }
        }
        .confirmationDialog(Text("Quit \(process.name)?"), isPresented: $confirm) {
            Button("Quit process", role: .destructive) { kill(process.id, SIGTERM) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It isn’t an app with a window, so unsaved work in it may be lost.")
        }
    }
}

extension MemoryPressure {
    var label: LocalizedStringKey {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "High"
        }
    }
}
