import HelperShared
import MaintenanceKit
import SafetyKit
import SwiftUI

/// S15: classic maintenance tasks, each with a description, the exact command and whether it needs admin rights.
struct MaintenanceView: View {
    @Environment(AppModel.self) private var model
    @State private var running: MaintenanceTaskID?
    @State private var output: [MaintenanceTaskID: String] = [:]
    @State private var results: [MaintenanceTaskID: RunResult] = MaintenanceView.loadResults()
    @State private var confirmTask: MaintenanceTask?
    @State private var startedAt: Date?

    struct RunResult: Codable { var date: Date; var exitCode: Int32; var duration: Double; var failure: String? }

    var body: some View {
        VStack(spacing: 0) {
            HelperBanner()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(MaintenanceCatalog.all) { task in
                        TaskRow(task: task, isRunning: running == task.id, anyRunning: running != nil, output: output[task.id],
                                result: results[task.id], startedAt: running == task.id ? startedAt : nil) {
                            if task.id == .rebuildSpotlight { confirmTask = task } else { run(task) }
                        }
                        .kmGroup()
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 8)
                .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
            }
        }
        .confirmationDialog("Rebuild the Spotlight index?", isPresented: Binding(get: { confirmTask != nil }, set: { if !$0 { confirmTask = nil } }), presenting: confirmTask) { task in
            Button("Rebuild index") { run(task) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Search results are incomplete for about an hour while macOS indexes Macintosh HD again.")
        }
    }

    private func run(_ task: MaintenanceTask) {
        guard !VisualFixtures.enabled, running == nil else { return }
        running = task.id
        startedAt = Date()
        output[task.id] = ""
        let helper: HelperClient? = model.helper.isEnabled ? model.helper.client : nil
        let runner = MaintenanceRunner(runner: ProcessCommandRunner(), helper: helper)
        Task {
            var failure: String?
            var exit: Int32 = MaintenanceRunner.notRunExitCode
            var duration: TimeInterval = 0
            for await event in runner.run(task) {
                switch event {
                case .output(let line):
                    output[task.id, default: ""] += line + "\n"
                case .failed(let f):
                    failure = f.englishDescription
                case .finished(let code, let d):
                    exit = code; duration = d
                }
            }
            let result = RunResult(date: Date(), exitCode: exit, duration: duration, failure: failure)
            results[task.id] = result
            MaintenanceView.saveResults(results)
            running = nil
            await model.operationLog.record([OperationEntry(batchID: UUID(), kind: .maintenance, title: String(localized: task.id.title),
                                                            path: task.commandLine, bytes: 0, result: exit == 0 && failure == nil ? .ran : .failed,
                                                            reason: failure ?? (exit == 0 ? nil : "Exit code \(exit)"))])
        }
    }

    static func loadResults() -> [MaintenanceTaskID: RunResult] {
        guard let data = UserDefaults.standard.data(forKey: "maintenanceResults"),
              let raw = try? JSONDecoder().decode([String: RunResult].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in MaintenanceTaskID(rawValue: k).map { ($0, v) } })
    }

    static func saveResults(_ r: [MaintenanceTaskID: RunResult]) {
        let raw = Dictionary(uniqueKeysWithValues: r.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: "maintenanceResults")
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: MaintenanceTask
    let isRunning: Bool
    let anyRunning: Bool
    let output: String?
    let result: MaintenanceView.RunResult?
    let startedAt: Date?
    let run: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(task.id.title).font(.title3.weight(.semibold))
                    if task.needsAdmin {
                        Text("Admin")
                            .font(.caption)
                            .foregroundStyle(.kmFgMuted)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(task.id.detail).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
                CommandLabel(command: task.commandLine)
                if let output, !output.isEmpty, isRunning || result != nil {
                    ScrollView {
                        Text(verbatim: output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    .padding(8)
                    .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                if let reason = task.unavailableReason {
                    Text(reason.message).font(.callout).foregroundStyle(.kmFgMuted).multilineTextAlignment(.trailing)
                } else if isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        if let startedAt {
                            Text(startedAt, style: .timer).tabular().foregroundStyle(.kmFgMuted)
                        }
                    }
                } else if task.needsAdmin && !model.helper.isEnabled {
                    Button("Install helper…") { model.helper.install() }
                    Text("Needs the KeelMac helper").font(.callout).foregroundStyle(.kmFgMuted)
                } else {
                    Button(task.id == .rebuildSpotlight ? "Run…" : "Run", action: run).disabled(anyRunning)
                }
                if let result, !isRunning {
                    if let failure = result.failure {
                        Text(LocalizedStringKey(failure)).font(.callout).foregroundStyle(.kmDanger).multilineTextAlignment(.trailing)
                    } else if result.exitCode == 0 {
                        Text("Finished \(result.date.formatted(.relative(presentation: .named))) in \(Int(result.duration.rounded())) s")
                            .font(.callout).foregroundStyle(.kmFgMuted).tabular()
                    } else {
                        Text("Exit code \(result.exitCode)").font(.callout).foregroundStyle(.kmDanger).tabular()
                    }
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

/// Shows the helper's state above admin tasks and login items.
struct HelperBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.helper.status {
        case .enabled:
            EmptyView()
        case .requiresApproval:
            PermissionBanner(title: "Allow the KeelMac helper.", message: "Turn on KeelMac under Allow in the Background in Login Items.",
                             actionTitle: "Open Login Items") { model.helper.openApprovalSettings() }
        default:
            PermissionBanner(title: "Some tasks need administrator rights.",
                             message: "KeelMac installs a small helper that can only run the tasks listed here.",
                             actionTitle: "Install helper…") { model.helper.install() }
        }
    }
}

extension MaintenanceTaskID {
    var title: LocalizedStringResource {
        switch self {
        case .flushDNS: "Flush DNS cache"
        case .rebuildLaunchServices: "Rebuild Launch Services database"
        case .rebuildSpotlight: "Rebuild Spotlight index"
        case .verifyStartupDisk: "Verify startup disk"
        case .clearFontCaches: "Clear font caches"
        case .thinLocalSnapshots: "Thin local Time Machine snapshots"
        case .runPeriodic: "Run periodic maintenance scripts"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .flushDNS: "Clears cached name lookups. Useful after changing networks, VPNs or your hosts file."
        case .rebuildLaunchServices: "Fixes duplicate apps in “Open With” menus and wrong default apps."
        case .rebuildSpotlight: "Erases and rebuilds the index for Macintosh HD. Search results are incomplete for about an hour."
        case .verifyStartupDisk: "Read-only check of Macintosh HD with First Aid. Nothing is repaired."
        case .clearFontCaches: "Removes your font cache. Fixes garbled or missing fonts. Restart afterwards."
        case .thinLocalSnapshots: "Asks macOS to free up to 20 GB held by local snapshots. Your backups on the backup disk aren’t affected."
        case .runPeriodic: "Runs the daily, weekly and monthly housekeeping scripts macOS used to run overnight."
        }
    }
}

extension MaintenanceUnavailableReason {
    var message: LocalizedStringKey {
        switch self {
        case .toolMissing: "Not available on this version of macOS"
        }
    }
}

extension MaintenanceFailure {
    var englishDescription: String {
        switch self {
        case .unavailable: "Not available on this version of macOS"
        case .helperMissing: "Needs the KeelMac helper"
        case .helper(let e): "The helper didn’t respond: \(e)"
        case .rejected(let r): r.englishDescription
        case .timedOut: "Took too long and was stopped"
        }
    }
}
