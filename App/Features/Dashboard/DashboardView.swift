import MetricsKit
import ReportKit
import SwiftUI

/// S2: health, capacity, live metrics and the complete factor breakdown (C1–C3).
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
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Mac health", systemImage: "heart.text.square")
                                .font(.headline).foregroundStyle(.kmAccentText)
                            Text(report.band.sentence)
                                .font(.title2.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(report.score)").font(.largeTitle.weight(.semibold)).tabular()
                            Text("of 100").font(.callout).foregroundStyle(.kmFgMuted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .kmGroup()

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Macintosh HD", systemImage: "internaldrive").font(.headline)
                                Text(Format.bytes(inputs.diskAvailable)).font(.largeTitle.weight(.semibold)).tabular()
                                Text("Available space").foregroundStyle(.kmFgMuted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 8) {
                                Text("\(Format.bytes(inputs.diskTotal - inputs.diskAvailable)) used").fontWeight(.medium)
                                Text("\(Format.bytes(inputs.diskTotal)) total").foregroundStyle(.kmFgMuted)
                            }
                            .tabular()
                        }
                        LoadLineGauge(total: inputs.diskTotal, used: inputs.diskTotal - inputs.diskAvailable)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 24) {
                                loadLine(inputs)
                                Spacer()
                                storageExplanation(inputs).frame(maxWidth: 420)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                loadLine(inputs)
                                storageExplanation(inputs)
                            }
                        }
                    }
                    .kmGroup()

                    SummaryStrip(metrics: model.metrics)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Health breakdown").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        FactorLedger(report: report, inputs: inputs)
                    }
                    .kmGroup()
                }
                .padding(Metrics.pagePadding)
                .padding(.top, -12)
                .frame(maxWidth: Metrics.contentMaxWidth)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationSubtitle(Text("Updated \(Date.now.formatted(date: .omitted, time: .shortened))"))
        .assistantContext(.dashboard(report: report, inputs: inputs))
        .toolbar {
            ToolbarItem {
                Button("Refresh") { model.health.refreshCounts() }
            }
        }
        .onAppear { model.health.refreshCounts() }
        .onDisappear { model.health.cache(inputs) }
    }

    private func loadLine(_ inputs: HealthInputs) -> some View {
        LoadLineSentence(total: inputs.diskTotal, used: inputs.diskTotal - inputs.diskAvailable)
            .font(.callout.weight(.medium)).tabular()
    }

    private func storageExplanation(_ inputs: HealthInputs) -> some View {
        Text(LoadLine.marginBytes(total: inputs.diskTotal, used: inputs.diskTotal - inputs.diskAvailable) >= 0
             ? "The load line is 85% full. Keep below it so macOS has room for updates and swap."
             : "macOS needs free space for updates and swap. Cleanup and the storage map show what to remove.")
            .font(.callout).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
    }

}

private struct FactorLedger: View {
    @Environment(AppModel.self) private var model
    let report: HealthReport
    let inputs: HealthInputs

    var body: some View {
        VStack(spacing: 0) {
            ForEach(report.factors) { f in
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(f.id.title).fontWeight(.semibold)
                        why(f).foregroundStyle(.kmFgMuted).tabular().fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("\(f.points)/\(f.maxPoints)").font(.headline).tabular()
                        fixButton(f)
                    }
                }
                .padding(.vertical, 12)
                if f.id != report.factors.last?.id { Divider() }
            }
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
        case .startupItems(let total, let orphans, let over):
            if orphans > 0 { return Text("\(total) start on their own, \(orphans) from apps that are gone") }
            return over > 0 ? Text("\(total) start on their own, \(over) more than the \(HealthScore.startupItemAllowance) that are free")
                : Text("\(total) start on their own, within the \(HealthScore.startupItemAllowance) that are free")
        }
    }
}

private struct SummaryStrip: View {
    let metrics: MetricsMonitor

    var body: some View {
        let s = metrics.latest
        MetricColumns {
            cell("CPU", s?.cpu.map { Text(Format.percent($0.total)) }, s?.cpu.map { Text("\($0.perCore.count) cores") })
            cell("Memory", s?.memory.map { Text(Format.percent(Double($0.usedBytes) / Double(max($0.totalBytes, 1)))) },
                 s?.memory.map { m in Text("\(Format.memory(m.usedBytes)) of \(Format.memory(m.totalBytes)), pressure ") + Text(m.pressure.label) })
            cell("Battery", metrics.battery.flatMap { b in b.isPresent ? b.chargePercent.map { Text("\($0)%") } : Text("No battery") },
                 metrics.battery.flatMap { b in b.isPresent ? (b.isCharging ? Text("Charging") : b.isPluggedIn ? Text("Plugged in") : Text("On battery")) : nil })
            cell("Uptime", Text(Duration.seconds(metrics.systemInfo.uptime(now: .now)).formatted(.units(allowed: [.days, .hours], width: .abbreviated, maximumUnitCount: 2))),
                 Text(verbatim: "macOS \(metrics.systemInfo.macOSVersion), \(metrics.systemInfo.chip)"))
        }
        .tabular()
    }

    private func cell(_ title: LocalizedStringKey, _ value: Text?, _ caption: Text?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.kmFgMuted)
            (value ?? Text("Measuring…")).font(.title.weight(.semibold))
            (caption ?? Text(verbatim: " ")).font(.callout).foregroundStyle(.kmFgMuted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .kmGroup()
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
        case .loginItems: "See recommendations"
        }
    }
}
