import MetricsKit
import SwiftUI

/// S3: four live charts, top processes with Quit, battery details.
struct MonitorView: View {
    @Environment(AppModel.self) private var model
    @State private var sort: ProcessSort = .cpu

    var body: some View {
        let m = model.metrics
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MetricColumns {
                        ChartCell(title: "CPU", value: m.latest?.cpu.map { Text(Format.percent($0.total)) }, points: m.history.elements, kind: .cpu)
                        ChartCell(title: "Memory pressure", value: m.latest?.memory.map { Text($0.pressure.label) }, points: m.history.elements, kind: .memory,
                                  caption: m.latest?.memory.map { Text("\(Format.memory($0.usedBytes)) of \(Format.memory($0.totalBytes)) used") })
                        ChartCell(title: "Network", value: m.latest?.network.map { Text("In \(Format.rate($0.bytesInPerSecond))") }, points: m.history.elements, kind: .network,
                                  caption: m.latest?.network.map { Text("Out \(Format.rate($0.bytesOutPerSecond))") })
                        ChartCell(title: "Temperature", value: m.temperature.map { Text(Format.temperature($0)) } ?? (m.latest == nil ? nil : Text("Unavailable")),
                                  points: m.history.elements, kind: .temperature,
                                  caption: m.latest?.temperatureCelsius == nil && m.battery?.temperatureCelsius != nil ? Text("Battery sensor") : nil)
                    }

                    let layout = geometry.size.width >= 1040
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                    layout {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Top processes").font(.title2.weight(.semibold))
                                Spacer()
                                Picker("Sort by", selection: $sort) {
                                    Text("CPU").tag(ProcessSort.cpu)
                                    Text("Memory").tag(ProcessSort.memory)
                                }
                                .pickerStyle(.segmented).tint(.kmControlAccent).labelsHidden().fixedSize()
                            }
                            ProcessTable(processes: sort.top(m.processes, count: 12))
                                .frame(height: 420)
                        }
                        .frame(maxWidth: .infinity)
                        .kmGroup()
                        BatteryPanel(battery: m.battery, system: m.systemInfo)
                            .frame(width: geometry.size.width >= 1040 ? 300 : nil)
                    }
                }
                .padding(Metrics.pagePadding)
                .padding(.top, -12)
                .frame(maxWidth: Metrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.kmFgMuted)
            (value ?? Text("Measuring…").foregroundStyle(.kmFgMuted))
                .font(.title.weight(.semibold)).tabular()
            if let caption { caption.font(.caption).foregroundStyle(.kmFgMuted).tabular() } else { Text(verbatim: " ").font(.caption) }
            HistoryChart(points: points, kind: kind).frame(height: 80).padding(.top, 8)
            Text("Last 60 minutes").font(.caption).foregroundStyle(.kmFgMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .kmGroup()
    }
}

private struct ProcessTable: View {
    let processes: [ProcessSample]

    var body: some View {
        if processes.isEmpty {
            Text("Measuring…").foregroundStyle(.kmFgMuted).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Table(processes) {
                TableColumn("Process") { p in Text(verbatim: p.name).fontWeight(.medium).lineLimit(1).frame(minHeight: Metrics.rowHeight) }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Battery").font(.title2.weight(.semibold))
            if let b = battery, b.isPresent {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
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
            Text("This Mac").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
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
