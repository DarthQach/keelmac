import AppsKit
import ReportKit
import SafetyKit
import SwiftUI

/// S13: files left by apps that are no longer installed (C17).
struct LeftoversView: View {
    @Environment(AppModel.self) private var model
    @State private var excluded: Set<String> = []
    @State private var confirm = false

    private var groups: [LeftoverGroup] { model.apps.leftovers ?? [] }
    private var chosen: [RelatedFile] { groups.flatMap(\.files).filter { !excluded.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                PermissionBanner(title: "Full Disk Access is off.", message: "Some app data folders can’t be measured.",
                                 actionTitle: "Open Privacy & Security") { model.openFullDiskAccessSettings() }
            }
            if model.apps.leftovers == nil {
                ProgressView("Searching your Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                EmptyStateView(symbol: "shippingbox", title: "No leftovers from deleted apps",
                               message: "Files in your Library from apps that are no longer installed appear here. Apple’s own folders and anything an installed app uses are never listed.")
            } else {
                List {
                    Section {
                        Text("Files in your Library from apps that are no longer installed. Apple’s own folders and anything shared by an installed app are never listed.")
                            .foregroundStyle(.kmFgMuted)
                    }
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.files) { f in
                                HStack {
                                    Toggle(isOn: Binding(get: { !excluded.contains(f.id) }, set: { on in if on { excluded.remove(f.id) } else { excluded.insert(f.id) } })) {
                                        FileIdentity(name: (f.path as NSString).lastPathComponent, path: (f.path as NSString).deletingLastPathComponent)
                                    }
                                    .toggleStyle(.checkbox)
                                    Spacer()
                                    Text(Format.bytes(f.bytes)).tabular().foregroundStyle(.kmFgMuted)
                                }
                                .contextMenu { Button("Reveal in Finder") { FileActions.reveal([f.path]) } }
                            }
                        } header: {
                            HStack {
                                TriStateBox(state: state(g)) { toggle(g) }
                                Text(verbatim: g.displayName).font(.headline).foregroundStyle(.kmFg)
                                Text(verbatim: g.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.kmFgMuted)
                                Spacer()
                                Text(Format.bytes(g.bytes)).font(.headline).foregroundStyle(.kmFg).tabular()
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .kmTableSurface()
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 16)
                ActionBar {
                    Text("\(chosen.count) items selected, \(Format.bytes(chosen.reduce(0) { $0 + $1.bytes }))")
                } trailing: {
                    Button { confirm = true } label: { RemoveLabel(bytes: chosen.reduce(0) { $0 + $1.bytes }) }
                        .buttonStyle(.kmPrimary).disabled(chosen.isEmpty)
                }
            }
        }
        .toolbar { ToolbarItem { Button("Search again") { Task { await model.apps.loadLeftovers() } }.disabled(model.apps.loadingLeftovers) } }
        .task { if model.apps.leftovers == nil { await model.apps.loadLeftovers() } }
        .assistantContext(model.apps.leftovers.map(ScreenContext.leftovers))
        .confirmationDialog(Text("Move \(chosen.count) leftover items to the Trash?"), isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { Task { _ = await model.apps.removeLeftovers(chosen) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func state(_ g: LeftoverGroup) -> CleanupModel.CheckState {
        let n = g.files.filter { !excluded.contains($0.id) }.count
        return n == 0 ? .off : (n == g.files.count ? .on : .mixed)
    }

    private func toggle(_ g: LeftoverGroup) {
        let ids = g.files.map(\.id)
        if state(g) == .on { excluded.formUnion(ids) } else { excluded.subtract(ids) }
    }
}

/// S14: login items and background agents (C19).
struct LoginItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemove: LaunchItem?

    var body: some View {
        VStack(spacing: 0) {
            if let items = model.apps.launchItems, items.contains(where: \.needsHelper), !model.helper.isEnabled {
                HelperBanner()
            }
            if let items = model.apps.launchItems {
                if items.isEmpty {
                    EmptyStateView(symbol: "power", title: "No login items or background agents", message: "Agents and daemons that start with your Mac appear here.")
                } else {
                    StartupSummary(items: items, advice: model.apps.launchAdvice) { confirmRemove = $0 }
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.bottom, 16)
                    List {
                        section("Your agents", items.filter { $0.domain == .userAgent }, note: "~/Library/LaunchAgents")
                        section("Agents for every user", items.filter { $0.domain == .globalAgent }, note: "/Library/LaunchAgents")
                        section("System daemons", items.filter { $0.domain == .globalDaemon }, note: "/Library/LaunchDaemons")
                        Section {
                            HStack {
                                Text("Apps that open at login are managed in System Settings.").foregroundStyle(.kmFgMuted)
                                Spacer()
                                Button("Open Login Items") { model.helper.openApprovalSettings() }
                            }
                        }
                    }
                    .listStyle(.inset)
                .kmTableSurface()
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 16)
                }
            } else {
                ProgressView("Reading launchd…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(Text("Changes take effect at next login unless noted"))
        .toolbar { ToolbarItem { Button("Refresh") { Task { await model.apps.loadLaunchItems() } } } }
        .task { await model.apps.loadLaunchItems() }
        .assistantContext(model.apps.launchItems.map { ScreenContext.loginItems($0, advice: model.apps.launchAdvice) })
        .confirmationDialog(Text("Remove \(confirmRemove?.label ?? "")?"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { item in
            Button("Remove", role: .destructive) {
                Task { if let error = await model.apps.remove(item) { model.notice = error } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The item is stopped and its plist moves to the Trash. The app it belongs to may add it again when it next runs.")
        }
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey, _ items: [LaunchItem], note: String) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in LaunchRow(item: item, advice: model.apps.launchAdvice[item.id]) { confirmRemove = item } }
            } header: {
                HStack { Text(title).font(.headline).foregroundStyle(.kmFg); Text(verbatim: note).font(.system(.caption, design: .monospaced)) }
            }
        }
    }
}

private struct LaunchRow: View {
    @Environment(AppModel.self) private var model
    let item: LaunchItem
    let advice: LaunchAdvice?
    let remove: () -> Void
    @State private var busy = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: item.label).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                PathText(path: item.plistPath)
                if let advice {
                    (Text(advice.title).fontWeight(.medium).foregroundStyle(advice.isStrong ? Color.kmWarning : Color.kmFgMuted)
                        + Text(verbatim: " · ") + advice.reason(for: item).foregroundStyle(.kmFgMuted))
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !item.countsTowardStartup {
                    Text(item.isDisabled ? "Off, so it doesn’t count toward the score" : "Runs only when needed, so it doesn’t count toward the score")
                        .font(.callout).foregroundStyle(.kmFgMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let owner = item.ownerName, item.ownerInstalled {
                    Text(verbatim: owner)
                } else {
                    Text("App not installed").foregroundStyle(.kmWarning)
                }
            }
            .frame(width: 110, alignment: .leading)
            Text(item.schedule.label).foregroundStyle(.kmFgMuted).frame(width: 90, alignment: .leading)
                .help(Text(item.schedule.explanation))
            if busy {
                ProgressView().controlSize(.small).frame(width: 40)
            } else {
                Toggle("Enabled", isOn: Binding(get: { !item.isDisabled }, set: { on in
                    busy = true
                    Task {
                        if let error = await model.apps.setEnabled(item, on) { model.notice = error }
                        busy = false
                    }
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(item.needsHelper && !model.helper.isEnabled)
                .accessibilityLabel(Text("Enabled"))
            }
            Button("Remove…", action: remove).disabled(item.needsHelper && !model.helper.isEnabled)
        }
        .frame(minHeight: Metrics.detailRowHeight)
        .padding(.vertical, 6)
    }
}

extension LaunchSchedule {
    var label: LocalizedStringKey {
        switch self {
        case .atLoad: "At login"
        case .keepAlive: "Kept alive"
        case .interval(let s): s >= 3600 ? "Every \(s / 3600) h" : "Every \(max(1, s / 60)) min"
        case .calendar: "On a schedule"
        case .onDemand: "On demand"
        }
    }

    /// The schedule in plain words, for the tooltip.
    var explanation: LocalizedStringKey {
        switch self {
        case .atLoad: "Starts once when you log in."
        case .keepAlive: "Starts when you log in and restarts whenever it stops."
        case .interval: "Starts on its own at a regular interval."
        case .calendar: "Starts on its own at set times."
        case .onDemand: "Starts only when another program needs it. It doesn’t count toward the score."
        }
    }
}

/// Top of S14: what the startup items factor counts, why points are lost, and what KeelMac recommends.
private struct StartupSummary: View {
    @Environment(AppModel.self) private var model
    let items: [LaunchItem]
    let advice: [String: LaunchAdvice]
    let remove: (LaunchItem) -> Void
    @State private var busy: Set<String> = []

    private static let shownRecommendations = 5

    var body: some View {
        let counted = items.filter(\.countsTowardStartup)
        let orphans = counted.filter { !$0.ownerInstalled }.count
        let points = HealthScore.startupPoints(total: counted.count, orphans: orphans)
        let recommended = items.filter { advice[$0.id]?.isStrong == true }
        let fixed = recommended.filter(\.countsTowardStartup)
        let projected = HealthScore.startupPoints(total: counted.count - fixed.count,
                                                  orphans: orphans - fixed.filter { !$0.ownerInstalled }.count)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Startup items score").foregroundStyle(.kmFgMuted)
                    Text("\(points) of \(HealthScore.startupMaxPoints) points")
                        .font(.largeTitle.weight(.semibold)).tabular()
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Start on their own: \(counted.count)").font(.headline).tabular()
                    Group {
                        Text("Up to \(HealthScore.startupItemAllowance) are free; every 3 more cost 1 point.")
                        if orphans > 0 { Text("From apps you deleted: \(orphans), 2 points each.") }
                        Text("Items that are off or run only when needed don’t count.")
                    }
                    .font(.callout).foregroundStyle(.kmFgMuted).tabular()
                }
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 380, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !recommended.isEmpty {
                Divider()
                Text("Recommended").font(.headline)
                VStack(spacing: 10) {
                    ForEach(recommended.prefix(Self.shownRecommendations)) { item in row(item) }
                }
                if recommended.count > Self.shownRecommendations {
                    Text("\(recommended.count - Self.shownRecommendations) more are marked in the list below.")
                        .font(.callout).foregroundStyle(.kmFgMuted).tabular()
                }
            }
            footer(points: points, projected: projected, hasRecommendations: !recommended.isEmpty)
                .font(.callout).foregroundStyle(.kmFgMuted).tabular()
                .fixedSize(horizontal: false, vertical: true)
        }
        .kmGroup()
    }

    @ViewBuilder private func footer(points: Int, projected: Int, hasRecommendations: Bool) -> some View {
        let max = HealthScore.startupMaxPoints
        if points == max && !hasRecommendations {
            Text("Nothing to do here.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if points == max {
                    Text("Your score is already full. These are optional and only cut background activity.")
                }
                if hasRecommendations && projected > points {
                    Text("Doing these brings the score to \(projected) of \(max) points.")
                }
                if projected < max {
                    Text("To get the rest back, switch off items for apps or devices you don’t use. Every 3 fewer gives back a point.")
                }
                Text("Switching an item off is safe: it stops starting on its own, and you can switch it back on any time.")
            }
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        let a = advice[item.id]!
        let locked = item.needsHelper && !model.helper.isEnabled
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: item.ownerName ?? item.label).fontWeight(.medium).lineLimit(1)
                    if item.ownerName != nil {
                        Text(verbatim: item.label).font(.system(.caption, design: .monospaced)).foregroundStyle(.kmFgMuted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                a.reason(for: item).font(.callout).foregroundStyle(.kmFgMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy.contains(item.id) {
                ProgressView().controlSize(.small).frame(width: 80)
            } else if a.action == .remove {
                Button("Remove…") { remove(item) }.disabled(locked)
            } else {
                Button("Turn off") {
                    busy.insert(item.id)
                    Task {
                        if let error = await model.apps.setEnabled(item, false) { model.notice = error }
                        busy.remove(item.id)
                    }
                }
                .disabled(locked)
            }
        }
        .help(locked ? Text("Needs the KeelMac helper") : Text(verbatim: item.label))
    }
}

extension LaunchAdvice {
    var title: LocalizedStringKey {
        switch action {
        case .remove: "Recommended: remove"
        case .turnOff: isStrong ? "Recommended: turn off" : "Worth a look"
        }
    }

    /// One plain sentence a non-expert can act on.
    func reason(for item: LaunchItem) -> Text {
        let app = item.ownerName
        switch reason {
        case .appGone:
            return app.map { Text("\($0) is no longer installed, so this item has nothing left to do.") }
                ?? Text("The app it belongs to is no longer installed, so this item has nothing left to do.")
        case .duplicate(let other):
            let folder = ((other as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            return Text("The same item also runs from \(folder). One copy is enough.")
        case .updater:
            return app.map { Text("Only checks for updates. \($0) still updates itself when you open it.") }
                ?? Text("Only checks for updates. The app still updates itself when you open it.")
        case .appUnused(let lastUsed):
            let date = lastUsed.formatted(date: .abbreviated, time: .omitted)
            return app.map { Text("\($0) hasn’t been opened since \(date). If you no longer use it, you can turn this off.") }
                ?? Text("Its app hasn’t been opened since \(date). If you no longer use it, you can turn this off.")
        }
    }
}
