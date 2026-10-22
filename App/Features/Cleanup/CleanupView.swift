import CleanKit
import ReportKit
import SafetyKit
import SwiftUI

/// S8/S9: the dry-run preview of every cleanup category, per-item exclusion, then the result.
struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var confirm = false

    private var cleanup: CleanupModel { model.cleanup }

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess && cleanup.phase != .done {
                PermissionBanner(title: "Full Disk Access is off.", message: "Browser caches, the Trash and iPhone backups can’t be measured.",
                                 actionTitle: "Open Privacy & Security") { model.openFullDiskAccessSettings() }
            }
            content
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Check again") { Task { await cleanup.check(hasFullDiskAccess: model.hasFullDiskAccess) } }
                    .disabled(cleanup.phase == .planning || cleanup.phase == .cleaning)
            }
        }
        .task {
            if cleanup.phase == .idle { await cleanup.check(hasFullDiskAccess: model.hasFullDiskAccess) }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button(cleanup.selectionDeletesPermanently ? "Clean up" : "Move to Trash", role: .destructive) { Task { await cleanup.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in the Trash category, and everything when permanent delete is on in Settings, are deleted and can’t be put back.")
        }
    }

    private var subtitle: Text {
        guard let plan = cleanup.plan else { return Text(verbatim: "") }
        return Text("Checked \(plan.createdAt.formatted(.relative(presentation: .named)))")
    }

    @ViewBuilder private var content: some View {
        switch cleanup.phase {
        case .idle:
            if let error = cleanup.loadError {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn’t read the cleanup rules", message: LocalizedStringKey(error),
                               actionTitle: "Try again") { Task { await cleanup.check(hasFullDiskAccess: model.hasFullDiskAccess) } }
            } else {
                EmptyStateView(symbol: "trash", title: "Check what can be cleaned", message: "KeelMac measures caches, logs and developer leftovers. Nothing moves until you choose.",
                               actionTitle: "Check now") { Task { await cleanup.check(hasFullDiskAccess: model.hasFullDiskAccess) } }
            }
        case .planning:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Measuring caches, logs and developer leftovers…").foregroundStyle(.kmFgMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cleaning:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Moving \(cleanup.selectedCount) items to the Trash…").foregroundStyle(.kmFgMuted).tabular()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            if let result = cleanup.result { CleanupResultView(result: result) }
        case .ready:
            if let plan = cleanup.plan { preview(plan) }
        }
    }

    @ViewBuilder private func preview(_ plan: CleanupPlan) -> some View {
        let visible = plan.groups.filter { !$0.items.isEmpty || $0.status != .ready }
        if visible.allSatisfy({ $0.items.isEmpty }) {
            EmptyStateView(symbol: "checkmark.circle", title: "Nothing to clean right now.",
                           message: "Last checked \(plan.createdAt.formatted(.relative(presentation: .named))). KeelMac checks again each time you open Cleanup.")
        } else {
            VStack(spacing: 0) {
                List {
                    Section {
                        Text("This is a preview. Nothing moves until you click the button below, and only the items checked here.")
                            .foregroundStyle(.kmFgMuted)
                    }
                    ForEach(CleanupCategory.allCases, id: \.self) { category in
                        let groups = visible.filter { $0.category == category }
                        if !groups.isEmpty {
                            Section {
                                ForEach(groups) { group in GroupRow(group: group, expanded: $expanded) }
                            } header: {
                                CategoryHeader(category: category, groups: groups)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                ActionBar {
                    HStack(spacing: 4) {
                        Text("\(cleanup.selectedCount) items selected, \(Format.bytes(cleanup.selectedBytes)).")
                        Text(FileActions.deleteMode == .permanent ? "Items are deleted permanently." : "Items go to the Trash.")
                            .foregroundStyle(.kmFgMuted)
                    }
                } trailing: {
                    Button { confirm = true } label: { RemoveLabel(bytes: cleanup.selectedBytes) }
                        .buttonStyle(.kmPrimary)
                        .disabled(cleanup.selected.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var confirmTitle: Text {
        let size = Format.bytes(cleanup.selectedBytes)
        return cleanup.selectionDeletesPermanently
            ? Text("Clean up \(size)? Some items are deleted permanently.")
            : Text("Move \(cleanup.selectedCount) items (\(size)) to the Trash?")
    }
}

/// Tri-state checkbox (all, some, none).
struct TriStateBox: View {
    let state: CleanupModel.CheckState
    var disabled = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(state == .off || disabled ? Color.kmBorderStrong : Color.kmAccent)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityValue(state == .on ? Text("Checked") : state == .mixed ? Text("Partly checked") : Text("Not checked"))
    }
}

private struct CategoryHeader: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    let groups: [CleanupGroup]

    var body: some View {
        let ids = groups.flatMap { $0.items.map(\.id) }
        HStack(spacing: 8) {
            TriStateBox(state: model.cleanup.state(of: ids), disabled: ids.isEmpty) { model.cleanup.toggle(ids) }
                .accessibilityLabel(Text(category.title))
            Text(category.title).font(.headline).foregroundStyle(.kmFg)
            Text(category.subtitle).foregroundStyle(.kmFgMuted).lineLimit(1)
            Spacer()
            Text(Format.bytes(groups.reduce(0) { $0 + $1.bytes })).font(.headline).foregroundStyle(.kmFg).tabular()
        }
        .padding(.vertical, 4)
    }
}

private struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: CleanupGroup
    @Binding var expanded: Set<String>

    private var lang: String { Locale.current.language.languageCode?.identifier ?? "en" }

    var body: some View {
        let ids = group.items.map(\.id)
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group.id) }, set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } })) {
            ForEach(group.items) { item in ItemRow(item: item) }
            if !group.skipped.isEmpty {
                ForEach(group.skipped) { s in
                    HStack {
                        PathText(path: s.path)
                        Spacer()
                        if case .appRunning(let bid) = s.reason {
                            Text("Skipped while \(RunningName.of(bid)) is open").font(.callout).foregroundStyle(.kmWarning)
                        }
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TriStateBox(state: model.cleanup.state(of: ids), disabled: ids.isEmpty) { model.cleanup.toggle(ids) }
                    .accessibilityLabel(Text(verbatim: group.rule.title.value(for: lang)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: group.rule.title.value(for: lang))
                        if group.deletesPermanently { Tag(text: "Deleted permanently") }
                        if group.isCommand { Tag(text: "Command") }
                        if group.rule.optIn && model.cleanup.state(of: ids) == .off && !ids.isEmpty { Tag(text: "Off by default") }
                    }
                    Text(verbatim: group.rule.detail.value(for: lang)).font(.callout).foregroundStyle(.kmFgMuted).lineLimit(2)
                    status
                }
                Spacer()
                Text(group.items.isEmpty ? "–" : Format.bytes(group.bytes)).tabular()
                    .foregroundStyle(model.cleanup.state(of: ids) == .off ? .kmFgMuted : .kmFg)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder private var status: some View {
        switch group.status {
        case .ready:
            if let cmd = group.items.first?.command { Text(verbatim: cmd.commandLine).font(.system(.caption, design: .monospaced)).foregroundStyle(.kmFgMuted) }
        case .needsFullDiskAccess:
            Text("Needs Full Disk Access").font(.callout).foregroundStyle(.kmWarning)
        case .toolMissing:
            Text("Not installed on this Mac").font(.callout).foregroundStyle(.kmFgMuted)
        case .toolNotResponding:
            Text("Installed but not running").font(.callout).foregroundStyle(.kmFgMuted)
        case .appRunning(let bid):
            Text("Skipped while \(RunningName.of(bid)) is open").font(.callout).foregroundStyle(.kmWarning)
        case .failed(let message):
            Text("Couldn’t measure: \(message)").font(.callout).foregroundStyle(.kmDanger).lineLimit(2)
        case .needsHelper:
            Text("Needs the KeelMac helper").font(.callout).foregroundStyle(.kmFgMuted)
        }
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.cleanup.selected.contains(item.id) }, set: { on in
                if on { model.cleanup.selected.insert(item.id) } else { model.cleanup.selected.remove(item.id) }
            })) { EmptyView() }
            .toggleStyle(.checkbox)
            .accessibilityLabel(Text(verbatim: item.path))
            VStack(alignment: .leading, spacing: 1) {
                if let title = detailTitle { Text(verbatim: title) }
                PathText(path: item.isCommand ? (item.command?.commandLine ?? item.path) : item.path)
            }
            Spacer()
            Text(Format.bytes(item.bytes)).tabular().foregroundStyle(.kmFgMuted)
        }
        .contextMenu {
            if !item.isCommand {
                Button("Reveal in Finder") { FileActions.reveal([item.path]) }
                Button("Never clean this…") { addToWhitelist(item.path) }
            }
        }
    }

    private var detailTitle: String? {
        switch item.detail {
        case .iosBackup(let info):
            let date = info.lastBackupDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
            return [info.deviceName, info.productVersion.map { "iOS \($0)" }, date].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        case .appLanguage(let app, _, let language):
            return "\(app): \(Locale.current.localizedString(forIdentifier: language) ?? language)"
        case .simulators(let devices):
            return devices.prefix(3).map { "\($0.name) (\($0.runtime))" }.joined(separator: ", ") + (devices.count > 3 ? "…" : "")
        default:
            return nil
        }
    }

    private func addToWhitelist(_ path: String) {
        var list = UserDefaults.standard.stringArray(forKey: Preferences.Key.whitelist) ?? []
        let entry = (path as NSString).abbreviatingWithTildeInPath
        if !list.contains(entry) { list.append(entry) }
        UserDefaults.standard.set(list, forKey: Preferences.Key.whitelist)
        model.cleanup.selected.remove(item.id)
    }
}

struct Tag: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.kmFgMuted)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: 4))
    }
}

enum RunningName {
    static func of(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

extension CleanupCategory {
    var title: LocalizedStringKey {
        switch self {
        case .developer: "Developer"
        case .userCaches: "App caches"
        case .browserCaches: "Browser caches"
        case .logs: "Logs and crash reports"
        case .installers: "Installers in Downloads"
        case .iosBackups: "Old iPhone and iPad backups"
        case .docker: "Docker"
        case .languageFiles: "App language files"
        case .trash: "Trash"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .developer: "Xcode, simulators, package managers"
        case .userCaches: "Rebuilt by apps as needed"
        case .browserCaches: "History and passwords are never touched"
        case .logs: "Older than 7 days"
        case .installers: ".dmg, .pkg and .xip files"
        case .iosBackups: "Unchecked until you choose them"
        case .docker: "Stopped containers and build cache"
        case .languageFiles: "Unsigned apps only, signed apps would break"
        case .trash: "Emptied permanently, on all volumes"
        }
    }
}
