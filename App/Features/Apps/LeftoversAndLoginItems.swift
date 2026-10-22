import AppsKit
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
                ForEach(items) { item in LaunchRow(item: item) { confirmRemove = item } }
            } header: {
                HStack { Text(title).font(.headline).foregroundStyle(.kmFg); Text(verbatim: note).font(.system(.caption, design: .monospaced)) }
            }
        }
    }
}

private struct LaunchRow: View {
    @Environment(AppModel.self) private var model
    let item: LaunchItem
    let remove: () -> Void
    @State private var busy = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: item.label).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                PathText(path: item.plistPath)
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
}
