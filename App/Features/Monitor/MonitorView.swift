import MetricsKit
import SwiftUI

/// S3: four live charts, top processes with Quit, battery details.
struct MonitorView: View {
    @Environment(AppModel.self) private var model
    @State private var sort: ProcessSort = .cpu

    var body: some View {
        let m = model.metrics
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ChartCell(title: "CPU", value: m.latest?.cpu.map { Text(Format.percent($0.total)) }, points: m.history.elements, kind: .cpu)
                        VRule()
                        ChartCell(title: "Memory pressure", value: m.latest?.memory.map { Text($0.pressure.label) }, points: m.history.elements, kind: .memory,
                                  caption: m.latest?.memory.map { Text("\(Format.memory($0.usedBytes)) of \(Format.memory($0.totalBytes)) used") })
                        VRule()
                        ChartCell(title: "Network", value: m.latest?.network.map { Text("In \(Format.rate($0.bytesInPerSecond))") }, points: m.history.elements, kind: .network,
                                  caption: m.latest?.network.map { Text("Out \(Format.rate($0.bytesOutPerSecond))") })
                        VRule()
                        ChartCell(title: "Temperature", value: m.temperature.map { Text(Format.temperature($0)) } ?? (m.latest == nil ? nil : Text("Unavailable")),
                                  points: m.history.elements, kind: .temperature,
                                  caption: m.latest?.temperatureCelsius == nil && m.battery?.temperatureCelsius != nil ? Text("Battery sensor") : nil)
                    }
                }
                .kmGroup(padding: 0)

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Top processes").font(.headline)
                            Spacer()
                            Picker("Sort by", selection: $sort) {
                                Text("CPU").tag(ProcessSort.cpu)
                                Text("Memory").tag(ProcessSort.memory)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        ProcessTable(processes: sort.top(m.processes, count: 12))
                            .frame(minHeight: 340)
                    }
                    .frame(maxWidth: .infinity)

                    BatteryPanel(battery: m.battery, system: m.systemInfo)
                        .frame(width: 290)
                }
            }
            .padding(Metrics.pagePadding)
        }
        .detailedMetrics(m)
    }
}

private struct ChartCell: View {
    let title: LocalizedStringKey
    let value: Text?
    let points: [HistoryPoint]
    let kind: ChartKind
    var caption: Text? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.kmFgMuted)
            (value ?? Text("Measuring…").foregroundStyle(.kmFgMuted))
                .font(.title3.weight(.semibold)).tabular()
            if let caption { caption.font(.caption).foregroundStyle(.kmFgMuted).tabular() } else { Text(verbatim: " ").font(.caption) }
            HistoryChart(points: points, kind: kind).frame(height: 56).padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProcessTable: View {
    let processes: [ProcessSample]

    var body: some View {
        if processes.isEmpty {
            Text("Measuring…").foregroundStyle(.kmFgMuted).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Table(processes) {
                TableColumn("Process") { p in Text(verbatim: p.name).lineLimit(1) }
                TableColumn("CPU") { p in Text(Format.percent(p.cpuPercent / 100, digits: 1)).tabular().frame(maxWidth: .infinity, alignment: .trailing) }.width(70)
                TableColumn("Memory") { p in Text(Format.memory(p.memoryBytes)).tabular().frame(maxWidth: .infinity, alignment: .trailing) }.width(90)
                TableColumn("User") { p in Text(verbatim: p.userName).foregroundStyle(.kmFgMuted) }.width(110)
                TableColumn("") { p in QuitButton(process: p, compact: true).frame(maxWidth: .infinity, alignment: .trailing) }.width(70)
            }
        }
    }
}

struct BatteryPanel: View {
    let battery: BatteryInfo?
    let system: SystemInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Battery").font(.headline)
            if let b = battery, b.isPresent {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    row("Charge", b.chargePercent.map { Text("\($0)%") }.map { t in b.isCharging ? t + Text(", charging") : (b.isPluggedIn ? t + Text(", plugged in") : t + Text(", on battery")) })
                    if let minutes = b.timeRemainingMinutes, minutes > 0, !b.isPluggedIn {
                        row("Time left", Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))))
                    }
                    row("Maximum capacity", b.maxCapacityPercent.map { Text(Format.percent($0 / 100)) })
                    row("Cycle count", b.cycleCount.map { Text("\($0)") })
                    row("Condition", b.condition.map { c in Text(LocalizedStringKey(c)).foregroundStyle(c == "Normal" ? .kmSuccess : .kmWarning) })
                    row("Temperature", b.temperatureCelsius.map { Text(Format.temperature($0)) })
                    row("Adapter", b.adapterWatts.map { Text("\($0) W") } ?? Text("Not connected"))
                }
                .tabular()
            } else {
                Text("This Mac has no battery.").foregroundStyle(.kmFgMuted)
            }
            Divider().padding(.vertical, 4)
            Text("This Mac").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("Model", Text(verbatim: system.modelName))
                row("Chip", Text(verbatim: system.chip))
                row("Memory", Text(Format.memory(system.memoryBytes)))
                row("macOS", Text(verbatim: "\(system.macOSVersion) (\(system.macOSBuild))"))
                row("Up", Text(Duration.seconds(system.uptime(now: .now)).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))))
            }
            .tabular()
        }
        .kmGroup()
    }

    private func row(_ title: LocalizedStringKey, _ value: Text?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.kmFgMuted)
            (value ?? Text(verbatim: "–"))
        }
    }
}
