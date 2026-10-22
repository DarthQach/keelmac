import MetricsKit
import ReportKit
import SwiftUI

/// S2: Health Score sentence, the load line, the factor ledger with fixes, and a summary strip (C1–C3).
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inputs = model.health.inputs(metrics: model.metrics)
        let report = HealthScore.compute(inputs)
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                PermissionBanner(title: "Full Disk Access is off.", message: "Reclaimable space is only partly measured.",
                                 actionTitle: "Open Privacy & Security") { model.openFullDiskAccessSettings() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.band.sentence)
                            .font(.system(size: 26, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("\(report.score) of 100").font(.title3).foregroundStyle(.kmFgMuted).tabular()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Macintosh HD").fontWeight(.semibold)
                            Spacer()
                            Text("\(Format.bytes(inputs.diskTotal - inputs.diskAvailable)) used of \(Format.bytes(inputs.diskTotal)), \(Format.bytes(inputs.diskAvailable)) free")
                                .foregroundStyle(.kmFgMuted).tabular()
                        }
                        LoadLineGauge(total: inputs.diskTotal, used: inputs.diskTotal - inputs.diskAvailable)
                        HStack(alignment: .firstTextBaseline) {
                            LoadLineSentence(total: inputs.diskTotal, used: inputs.diskTotal - inputs.diskAvailable)
                                .font(.headline).tabular()
                            Spacer()
                            Text(LoadLine.marginBytes(total: inputs.diskTotal, used: inputs.diskTotal - inputs.diskAvailable) >= 0
                                 ? "The load line is 85% full. Keep below it so macOS has room for updates and swap."
                                 : "macOS needs free space for updates and swap. Cleanup and the storage map show what to remove.")
                                .foregroundStyle(.kmFgMuted)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    FactorLedger(report: report, inputs: inputs)

                    SummaryStrip(metrics: model.metrics)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 1000, alignment: .leading)
            }
        }
        .navigationSubtitle(Text("Updated \(Date.now.formatted(date: .omitted, time: .shortened))"))
        .toolbar {
            ToolbarItem {
                Button("Refresh") { model.health.refreshCounts() }
            }
        }
        .onAppear { model.health.refreshCounts() }
        .onDisappear { model.health.cache(inputs) }
    }
}

private struct FactorLedger: View {
    @Environment(AppModel.self) private var model
    let report: HealthReport
    let inputs: HealthInputs

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text("Factor"); Text("Score").gridColumnAlignment(.trailing); Text("Why"); Text(verbatim: "")
            }
            .font(.callout).foregroundStyle(.kmFgMuted)
            .padding(.bottom, 6)
            ForEach(report.factors) { f in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(f.id.title)
                    Text("\(f.points)/\(f.maxPoints)").tabular()
                    why(f).foregroundStyle(.kmFgMuted).tabular()
                    fixButton(f)
                }
                .padding(.vertical, 9)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
        }
    }

    @ViewBuilder private func fixButton(_ f: HealthFactor) -> some View {
        if let route = f.fix, f.lostPoints > 0 || f.isUnmeasured {
            Button(route.label(for: f.id)) { model.route = route.route }
                .buttonStyle(.link)
                .foregroundStyle(.kmAccentText)
                .gridColumnAlignment(.trailing)
        } else {
            Text(verbatim: "")
        }
    }

    private func why(_ f: HealthFactor) -> Text {
        switch f.details {
        case .diskFree(_, let available, _, let margin):
            let m = Format.bytes(abs(margin))
            return margin >= 0 ? Text("\(Format.bytes(available)) free, \(m) above the load line") : Text("\(Format.bytes(available)) free, \(m) below the load line")
        case .memoryPressure(let warning, let critical):
            let minutes = model.metrics.historyMinutes
            if critical > 0 { return Text("High for \(Int((critical * minutes).rounded())) min in the last hour") }
            if warning > 0 { return Text("Elevated for \(Int((warning * minutes).rounded())) min in the last hour") }
            return Text("Normal for the last hour")
        case .battery(let has, let cap, let cycles):
            guard has else { return Text("This Mac has no battery") }
            if let cap, let cycles { return Text("\(Format.percent(cap / 100)) of design capacity after \(cycles) cycles") }
            return cap.map { Text("\(Format.percent($0 / 100)) of design capacity") } ?? Text("Measuring…")
        case .reclaimable(let bytes, _):
            guard let bytes else { return Text("Not checked yet. Open Cleanup to measure it.") }
            return bytes == 0 ? Text("Nothing to clean") : Text("\(Format.bytes(bytes)) ready to review in Cleanup")
        case .startupItems(let total, let orphans, _):
            return orphans > 0 ? Text("\(total) login items and agents, \(orphans) from apps that are gone")
                : Text("\(total) login items and agents, all from installed apps")
        }
    }
}

private struct SummaryStrip: View {
    let metrics: MetricsMonitor

    var body: some View {
        let s = metrics.latest
        Grid(horizontalSpacing: 0) {
            GridRow {
                cell("CPU", s?.cpu.map { Text(Format.percent($0.total)) }, s?.cpu.map { Text("\($0.perCore.count) cores") })
                VRule()
                cell("Memory", s?.memory.map { Text(Format.percent(Double($0.usedBytes) / Double(max($0.totalBytes, 1)))) },
                     s?.memory.map { m in Text("\(Format.memory(m.usedBytes)) of \(Format.memory(m.totalBytes)), pressure ") + Text(m.pressure.label) })
                VRule()
                cell("Battery", metrics.battery.flatMap { b in b.isPresent ? b.chargePercent.map { Text("\($0)%") } : Text("No battery") },
                     metrics.battery.flatMap { b in b.isPresent ? (b.isCharging ? Text("Charging") : b.isPluggedIn ? Text("Plugged in") : Text("On battery")) : nil })
                VRule()
                cell("Uptime", Text(Duration.seconds(metrics.systemInfo.uptime(now: .now)).formatted(.units(allowed: [.days, .hours], width: .abbreviated, maximumUnitCount: 2))),
                     Text(verbatim: "macOS \(metrics.systemInfo.macOSVersion), \(metrics.systemInfo.chip)"))
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .tabular()
    }

    private func cell(_ title: LocalizedStringKey, _ value: Text?, _ caption: Text?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout).foregroundStyle(.kmFgMuted)
            (value ?? Text("Measuring…")).font(.system(size: 17, weight: .semibold))
            (caption ?? Text(verbatim: " ")).font(.callout).foregroundStyle(.kmFgMuted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension HealthBand {
    var sentence: LocalizedStringKey {
        switch self {
        case .good: "Your Mac is in good shape."
        case .fair: "Your Mac could use some room."
        case .poor: "Your Mac needs attention."
        }
    }
}

extension HealthFactorKind {
    var title: LocalizedStringKey {
        switch self {
        case .diskFree: "Disk free"
        case .memoryPressure: "Memory pressure"
        case .battery: "Battery health"
        case .reclaimable: "Reclaimable space"
        case .startupItems: "Startup items"
        }
    }
}

extension FixRoute {
    var route: Route {
        switch self {
        case .storageMap: .storageMap
        case .monitor: .monitor
        case .cleanup: .cleanup
        case .loginItems: .loginItems
        }
    }

    func label(for kind: HealthFactorKind) -> LocalizedStringKey {
        switch self {
        case .storageMap: "Open storage map"
        case .monitor: kind == .battery ? "View battery" : "Show processes"
        case .cleanup: "Review cleanup"
        case .loginItems: "Review"
        }
    }
}
