import CleanKit
import ReportKit
import SafetyKit
import SwiftUI

/// S8/S9: the dry-run preview of every cleanup category, per-item exclusion, then the result.
struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var confirm = false
    @State private var selectedCategory: CleanupCategory?

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
            let present = CleanupCategory.allCases.filter { c in visible.contains { $0.category == c } }
            let withItems = present.filter { c in visible.contains { $0.category == c && !$0.items.isEmpty } }
                .sorted { plan.bytes(in: $0) > plan.bytes(in: $1) }
            let empty = present.filter { !withItems.contains($0) }
            let current = selectedCategory.flatMap { present.contains($0) ? $0 : nil } ?? withItems[0]
            VStack(spacing: 0) {
                CleanupSummary(plan: plan)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.bottom, 16)
                HStack(spacing: 0) {
                    CategorySidebar(plan: plan, categories: withItems, empty: empty,
                                    selection: Binding(get: { current }, set: { selectedCategory = $0 }))
                        .frame(width: 230)
                    Divider()
                    CategoryDetail(category: current, groups: visible.filter { $0.category == current }, expanded: $expanded)
                        .id(current)
                }
                .kmTableSurface()
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 16)
                ActionBar {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(cleanup.selectedCount) items selected, \(Format.bytes(cleanup.selectedBytes)).")
                        Text(cleanup.selectionDeletesPermanently ? "Some selected items are deleted permanently." : "Items go to the Trash.")
                            .foregroundStyle(.kmFgMuted)
                    }
                } trailing: {
                    Button { confirm = true } label: {
                        if cleanup.selectionDeletesPermanently { Text("Clean up \(Format.bytes(cleanup.selectedBytes))") }
                        else { RemoveLabel(bytes: cleanup.selectedBytes) }
                    }
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

private struct CleanupSummary: View {
    @Environment(AppModel.self) private var model
    let plan: CleanupPlan

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ready to review").foregroundStyle(.kmFgMuted)
                Text(Format.bytes(plan.groups.reduce(0) { $0 + $1.bytes }))
                    .font(.largeTitle.weight(.semibold)).tabular()
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(Format.bytes(model.cleanup.selectedBytes)) selected")
                    .font(.headline).tabular().foregroundStyle(.kmAccentText)
                Text("Nothing moves until you click the button below, and only what is checked.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .kmGroup()
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

extension CleanupPlan {
    func groups(in category: CleanupCategory) -> [CleanupGroup] { groups.filter { $0.category == category } }
    func bytes(in category: CleanupCategory) -> Int64 { groups(in: category).reduce(0) { $0 + $1.bytes } }
}

/// Left pane: what can be cleaned in total, then one row per category.
private struct CategorySidebar: View {
    @Environment(AppModel.self) private var model
    let plan: CleanupPlan
    let categories: [CleanupCategory]
    let empty: [CleanupCategory]
    @Binding var selection: CleanupCategory
    @State private var showEmpty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(categories, id: \.self) { row($0) }
                }
                .padding(8)
                if !empty.isEmpty {
                    DisclosureGroup(isExpanded: $showEmpty) {
                        VStack(spacing: 2) { ForEach(empty, id: \.self) { row($0) } }
                    } label: {
                        Text("Nothing to clean (\(empty.count))").foregroundStyle(.kmFgMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func row(_ category: CleanupCategory) -> some View {
        let ids = plan.groups(in: category).flatMap { $0.items.map(\.id) }
        let state = model.cleanup.state(of: ids)
        let isSelected = selection == category
        return HStack(spacing: 10) {
            TriStateBox(state: state, disabled: ids.isEmpty) { model.cleanup.toggle(ids) }
                .accessibilityLabel(Text(category.title))
            Image(systemName: category.symbol)
                .frame(width: 18)
                .foregroundStyle(isSelected ? .kmAccentText : .kmFgMuted)
            VStack(alignment: .leading, spacing: 5) {
                Text(category.title).fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(ids.isEmpty ? .kmFgMuted : .kmFg)
                    .fixedSize(horizontal: false, vertical: true)
                (ids.isEmpty ? Text(verbatim: "–") : Text(Format.bytes(plan.bytes(in: category))))
                    .font(.callout).tabular().foregroundStyle(.kmFgMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: Metrics.detailRowHeight)
        .padding(.vertical, 4)
        .background(isSelected ? Color.kmAccentSoft : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
        .contentShape(Rectangle())
        .onTapGesture { selection = category }
        .focusable()
        .onKeyPress(.return) { selection = category; return .handled }
        .onKeyPress(.space) { selection = category; return .handled }
        .accessibilityAction { selection = category }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Right pane: the selected category's rules, one line each; items open under a rule.
private struct CategoryDetail: View {
    let category: CleanupCategory
    let groups: [CleanupGroup]
    @Binding var expanded: Set<String>
    @State private var showUnavailable = false

    var body: some View {
        let available = groups.filter { !$0.items.isEmpty }.sorted { $0.bytes > $1.bytes }
        let unavailable = groups.filter { $0.items.isEmpty }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: category.symbol).font(.title3).foregroundStyle(.kmAccentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title).font(.title3.weight(.semibold))
                        Text(category.subtitle).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !available.isEmpty {
                        Text(Format.bytes(available.reduce(0) { $0 + $1.bytes })).font(.title3.weight(.semibold)).tabular()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
                Divider()
                ForEach(available) { group in
                    RuleRow(group: group, isExpanded: Binding(get: { expanded.contains(group.id) },
                                                              set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } }))
                    Divider().padding(.leading, 20)
                }
                if !unavailable.isEmpty {
                    if available.isEmpty {
                        VStack(alignment: .leading, spacing: 8) { ForEach(unavailable) { UnavailableRow(group: $0) } }
                            .padding(20)
                    } else {
                        DisclosureGroup(isExpanded: $showUnavailable) {
                            VStack(alignment: .leading, spacing: 8) { ForEach(unavailable) { UnavailableRow(group: $0) } }
                                .padding(.top, 8)
                        } label: {
                            Text("Not available here (\(unavailable.count))").foregroundStyle(.kmFgMuted)
                        }
                        .padding(20)
                    }
                }
            }
        }
    }
}

private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let group: CleanupGroup
    @Binding var isExpanded: Bool
    @State private var showAll = false
    @State private var showInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shownItems = 15
    private var lang: String { Locale.current.language.languageCode?.identifier ?? "en" }

    var body: some View {
        let ids = group.items.map(\.id)
        let state = model.cleanup.state(of: ids)
        let detail = group.rule.detail.value(for: lang)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TriStateBox(state: state) { model.cleanup.toggle(ids) }
                    .accessibilityLabel(Text(verbatim: group.rule.title.value(for: lang)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: group.rule.title.value(for: lang)).fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    if group.deletesPermanently { Tag(text: "Deleted permanently") }
                    if group.isCommand { Tag(text: "Command") }
                    if group.rule.optIn && state == .off { Tag(text: "Off by default") }
                    if group.items.count > 1 {
                        Text("\(group.items.count) items").font(.callout).foregroundStyle(.kmFgMuted).tabular()
                    }
                }
                Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.kmFgMuted)
                    .help(Text(verbatim: detail))
                    .accessibilityLabel(Text("About this item"))
                    .popover(isPresented: $showInfo) {
                        Text(verbatim: detail).padding(14).frame(width: 300).fixedSize(horizontal: false, vertical: true)
                    }
                Spacer(minLength: 8)
                Text(Format.bytes(group.bytes)).tabular()
                    .foregroundStyle(state == .off ? .kmFgMuted : .kmFg)
                    .frame(minWidth: 72, alignment: .trailing)
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.kmFgMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 24, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? Text("Collapse") : Text("Expand"))
                .accessibilityIdentifier("cleanup.disclosure.\(group.id)")
            }
            .padding(.horizontal, 20)
            .frame(minHeight: Metrics.detailRowHeight)
            .padding(.vertical, 8)
            .background(isExpanded ? Color.kmSurfaceMuted : Color.kmSurface)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isExpanded.toggle() } }
            .accessibilityAction(named: isExpanded ? Text("Collapse") : Text("Expand")) { isExpanded.toggle() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cleanup.rule.\(group.id)")
            if isExpanded { items }
        }
    }

    private var items: some View {
        let sorted = group.items.sorted { $0.bytes > $1.bytes }
        let shown = showAll ? sorted : Array(sorted.prefix(Self.shownItems))
        // When every item lives in the same folder, name the folder once instead of on each row.
        let parents = Set(group.items.filter { !$0.isCommand }.map { ($0.path as NSString).deletingLastPathComponent })
        let sharedParent = parents.count == 1 ? parents.first : nil
        return VStack(alignment: .leading, spacing: 0) {
            if let sharedParent {
                Text("In \((sharedParent as NSString).abbreviatingWithTildeInPath)")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.kmFgMuted)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.vertical, 4)
            }
            ForEach(shown) { ItemRow(item: $0, showsParent: sharedParent == nil) }
            if sorted.count > shown.count {
                Button("Show all \(sorted.count)") { showAll = true }.buttonStyle(.link).padding(.vertical, 6)
            }
            ForEach(group.skipped) { s in
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle").foregroundStyle(.kmWarning).frame(width: 16)
                    Text(verbatim: (s.path as NSString).lastPathComponent).lineLimit(1)
                    if case .appRunning(let bid) = s.reason {
                        Text("Skipped while \(RunningName.of(bid)) is open").font(.callout).foregroundStyle(.kmWarning).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .help(s.path)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(.kmAccent).frame(width: 2) }
        .padding(.leading, 24)
        .padding(.trailing, 20)
        .padding(.bottom, 12)
    }
}

/// A rule with nothing to offer here, with the reason.
private struct UnavailableRow: View {
    let group: CleanupGroup
    private var lang: String { Locale.current.language.languageCode?.identifier ?? "en" }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: group.rule.title.value(for: lang)).foregroundStyle(.kmFgMuted)
            Spacer(minLength: 8)
            reason.font(.callout)
        }
        .frame(minHeight: Metrics.rowHeight)
        .help(Text(verbatim: group.rule.detail.value(for: lang)))
    }

    @ViewBuilder private var reason: some View {
        switch group.status {
        case .ready:
            Text("Nothing found").foregroundStyle(.kmFgMuted)
        case .needsFullDiskAccess:
            Text("Needs Full Disk Access").foregroundStyle(.kmWarning)
        case .toolMissing:
            Text("Not installed on this Mac").foregroundStyle(.kmFgMuted)
        case .toolNotResponding:
            Text("Installed but not running").foregroundStyle(.kmFgMuted)
        case .appRunning(let bid):
            Text("Skipped while \(RunningName.of(bid)) is open").foregroundStyle(.kmWarning)
        case .failed(let message):
            Text("Couldn’t measure: \(message)").foregroundStyle(.kmDanger).lineLimit(2)
        case .needsHelper:
            Text("Needs the KeelMac helper").foregroundStyle(.kmFgMuted)
        }
    }
}

/// One item under an opened rule: its name first, where it lives after.
private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem
    var showsParent = true

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.cleanup.selected.contains(item.id) }, set: { on in
                if on { model.cleanup.selected.insert(item.id) } else { model.cleanup.selected.remove(item.id) }
            })) { EmptyView() }
            .toggleStyle(.checkbox)
            .accessibilityLabel(Text(verbatim: name))
            Image(systemName: item.isCommand ? "terminal" : item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.kmFgMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: name)
                    .font(item.isCommand ? .system(.callout, design: .monospaced) : .body)
                    .lineLimit(1).truncationMode(.middle)
                if !item.isCommand && showsParent {
                    PathText(path: (item.path as NSString).deletingLastPathComponent)
                }
            }
            Spacer(minLength: 8)
            Text(Format.bytes(item.bytes)).tabular().foregroundStyle(.kmFgMuted)
        }
        .frame(minHeight: showsParent ? Metrics.detailRowHeight : Metrics.rowHeight)
        .padding(.vertical, 4)
        .help(item.isCommand ? (item.command?.commandLine ?? item.path) : item.path)
        .contextMenu {
            if !item.isCommand {
                Button("Reveal in Finder") { FileActions.reveal([item.path]) }
                Button("Never clean this…") { addToWhitelist(item.path) }
            }
        }
    }

    private var name: String {
        if item.isCommand { return item.command?.commandLine ?? item.path }
        return detailTitle ?? (item.path as NSString).lastPathComponent
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
    var symbol: String {
        switch self {
        case .developer: "hammer"
        case .userCaches: "shippingbox"
        case .browserCaches: "globe"
        case .logs: "doc.text.magnifyingglass"
        case .installers: "arrow.down.app"
        case .iosBackups: "iphone"
        case .docker: "cube"
        case .languageFiles: "character.bubble"
        case .trash: "trash"
        }
    }

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
