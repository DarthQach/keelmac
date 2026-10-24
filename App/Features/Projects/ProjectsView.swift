import ProjectsKit
import SafetyKit
import SwiftUI

/// S22: project folders checked against git and GitHub; the ones already on GitHub and untouched can go to the
/// Trash, the others can be backed up (C34).
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.Key.projectsVerifyGitHub) private var verify = false
    @AppStorage(Preferences.Key.projectStaleDays) private var staleDays = 180
    @State private var sortOrder: [KeyPathComparator<ProjectScan>] = []

    private var projects: ProjectsModel { model.projects }

    private var rows: [ProjectScan] {
        sortOrder.isEmpty ? projects.visible : projects.visible.sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var projects = model.projects
        VStack(spacing: 0) {
            header
            content
            if projects.phase == .ready, !projects.scans.isEmpty { actionBar }
        }
        .toolbar {
            ToolbarItem { Button("Choose folders…", action: chooseFolders) }
            ToolbarItem {
                if projects.phase == .checking {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                        .help("Checking your projects…")
                } else {
                    Button("Check again") { Task { await projects.check() } }
                        .disabled(projects.roots.isEmpty)
                }
            }
        }
        .onChange(of: verify) { _, _ in Task { await projects.check() } }
        .task { if projects.phase == .idle { await projects.check() } }
        .sheet(isPresented: $projects.showTrashSheet) { ProjectTrashSheet() }
        .sheet(item: $projects.backupTarget) { ProjectBackupSheet(project: $0) }
        .sheet(isPresented: $projects.showBulkBackupSheet) { ProjectBulkBackupSheet() }
        .assistantContext(.projects(projects, selected: projects.selectedScans))
    }

    // MARK: Header

    private var header: some View {
        @Bindable var projects = model.projects
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PathText(path: projects.roots.joined(separator: ", "))
                Spacer(minLength: 12)
                Toggle("Verify with GitHub", isOn: $verify)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Compare every branch and tag with GitHub through git and your gh login. Off by default.")
                    .accessibilityIdentifier("projects.verify")
            }
            if let github = projects.github {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusBadge(text: LocalizedStringKey(github.title), tone: github.tone)
                    Text(verbatim: github.detail).foregroundStyle(.kmFgMuted).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if github == .notSignedIn { CommandLabel(command: "gh auth login").fixedSize() }
                }
            }
            if !projects.unreadableRoots.isEmpty, projects.loadError == nil {
                Text("Couldn’t read: \(projects.unreadableRoots.joined(separator: ", "))").foregroundStyle(.kmWarning).font(.callout)
            }
            if projects.phase != .idle, !projects.scans.isEmpty || projects.phase == .checking {
                Picker("Show", selection: $projects.filter) {
                    ForEach(ProjectsModel.Filter.allCases) { f in
                        Text(verbatim: "\(f.title) \(projects.count(f))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("projects.filter")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.bottom, 16)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if projects.roots.isEmpty {
            EmptyStateView(symbol: "folder.badge.gearshape", title: "Choose a folder where your projects live",
                           message: "KeelMac looks at each folder inside it: whether it uses git, what is on GitHub and when you last changed it. Nothing changes until you choose.",
                           actionTitle: "Choose folders…", action: chooseFolders)
        } else if let error = projects.loadError {
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn’t check your projects", message: LocalizedStringKey(error),
                           actionTitle: "Try again") { Task { await projects.check() } }
        } else if projects.scans.isEmpty {
            switch projects.phase {
            case .idle:
                EmptyStateView(symbol: "folder.badge.gearshape", title: "Check your projects",
                               message: "See which projects are safely on GitHub and which exist only on this Mac.",
                               actionTitle: "Check now") { Task { await projects.check() } }
            case .checking:
                progress.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                EmptyStateView(symbol: "folder", title: "No projects here",
                               message: "\(projects.roots.joined(separator: ", ")) has no folders inside. Choose another folder with Choose folders….")
            }
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    table
                    if projects.phase == .checking { progress.padding(.vertical, 4) }
                }
                .frame(maxWidth: .infinity)
                ScrollView {
                    inspector.frame(maxWidth: .infinity, alignment: .leading).kmGroup()
                }
                .frame(width: 240)
                .padding(.leading, 16)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 16)
        }
    }

    private var progress: some View {
        VStack(spacing: 8) {
            ProgressView(value: projects.total > 0 ? Double(projects.checked) / Double(projects.total) : nil).frame(maxWidth: 420)
            Text("Checking \(projects.checked) of \(projects.total) projects…").foregroundStyle(.kmFgMuted).tabular()
        }
    }

    private var table: some View {
        @Bindable var projects = model.projects
        return Table(rows, selection: $projects.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { p in
                HStack(spacing: 12) {
                    Image(systemName: p.verdict == .noGit ? "folder" : "folder.badge.gearshape").foregroundStyle(.kmFgMuted).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: p.relativePath).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: p.githubText).font(.callout).foregroundStyle(.kmFgMuted).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(minHeight: Metrics.detailRowHeight, alignment: .leading)
                .help(p.path)
            }
            .width(min: 160, ideal: 230)
            TableColumn("Status", value: \.sortRank) { p in
                StatusBadge(text: LocalizedStringKey(p.statusTitle), tone: p.statusTone)
                    .help(p.reasonSummary.isEmpty ? p.verdict.explanation : p.reasonSummary)
            }
            .width(min: 130, ideal: 160)
            TableColumn("Last change", value: \.sortLastChange) { p in
                Text(p.lastChange.map { Format.relative($0) } ?? String(localized: "Unknown"))
                    .tabular().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Size", value: \.sortBytes) { p in
                Text(p.measure.map { Format.bytes($0.bytes) } ?? "–").tabular().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
        }
        .kmTableSurface()
        .accessibilityIdentifier("projects.table")
        .contextMenu(forSelectionType: ProjectScan.ID.self) { ids in
            let chosen = model.projects.scans.filter { ids.contains($0.id) }
            if chosen.count == 1, let p = chosen.first {
                if p.canBackUp { Button("Back up…") { model.projects.backupTarget = p } }
                if let url = p.githubURL { Button("Open on GitHub") { NSWorkspace.shared.open(url) } }
                Button("Reveal in Finder") { FileActions.reveal(Array(ids)) }
            } else if chosen.count > 1 {
                let backable = chosen.filter(\.canBackUp)
                if backable.count > 1 {
                    Button("Back up \(backable.count) projects…") { model.projects.openBackup(backable) }
                } else if backable.count == 1 {
                    Button("Back up…") { model.projects.openBackup(backable) }
                }
                Button("Reveal in Finder") { FileActions.reveal(Array(ids)) }
            }
        }
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        let selected = projects.selectedScans
        if selected.count == 1, let p = selected.first {
            ProjectInspector(project: p, staleDays: staleDays) { model.projects.backupTarget = p }
        } else if selected.count > 1 {
            let backable = selected.filter(\.canBackUp)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(selected.count) projects selected").font(.headline)
                Text(Format.bytes(selected.reduce(0) { $0 + ($1.measure?.bytes ?? 0) })).tabular().foregroundStyle(.kmFgMuted)
                if !backable.isEmpty {
                    backUpButton(backable).padding(.top, 6)
                    let others = selected.count - backable.count
                    if others > 0 {
                        Group {
                            others == 1 ? Text("One of them is already on GitHub or can’t be backed up.")
                                : Text("\(others) of them are already on GitHub or can’t be backed up.")
                        }
                        .font(.callout).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("How Projects decides").font(.headline)
                Text("Safe to remove: every branch, tag and change is on GitHub, and neither a commit nor a file changed in \(staleDays) days.")
                Text("Not backed up: some work exists only here. Back up commits it and pushes it to a private repository.")
                Text("Generated folders like node_modules and build count toward size, not toward the last change.")
            }
            .font(.callout)
            .foregroundStyle(.kmFgMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Action bar

    /// Not backed up and No git are where backups happen; every other filter keeps the Trash bar.
    @ViewBuilder private var actionBar: some View {
        if projects.filter == .notBackedUp || projects.filter == .noGit { backupBar } else { trashBar }
    }

    private var backupBar: some View {
        let candidates = projects.backUpCandidates
        let chosen = projects.selectedBackableInFilter
        return ActionBar {
            if candidates.isEmpty {
                Text("Nothing here can be backed up.")
            } else {
                Text("\(chosen.count) of \(candidates.count) projects selected, \(Format.bytes(projects.selectedBackableBytes)). You see every command before anything runs.")
            }
        } trailing: {
            if !candidates.isEmpty, chosen.count < candidates.count {
                Button("Select all") { projects.selectAllBackable() }
            }
            backUpButton(chosen)
                .buttonStyle(.kmPrimary)
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier("projects.backup")
        }
    }

    private func backUpButton(_ chosen: [ProjectScan]) -> Button<Text> {
        Button { model.projects.openBackup(chosen) } label: {
            chosen.count > 1 ? Text("Back up \(chosen.count) projects…") : Text("Back up…")
        }
    }

    private var trashBar: some View {
        ActionBar {
            if projects.trashCandidates.isEmpty {
                if projects.unverifiedCount > 0 {
                    Text("Turn on Verify with GitHub to move projects to the Trash. \(projects.unverifiedCount) look safe but aren’t proved yet.")
                } else {
                    Text("Nothing is safe to remove yet. Projects always go to the Trash.")
                }
            } else {
                Text("\(projects.selectedTrashable.count) of \(projects.trashCandidates.count) safe projects selected, \(Format.bytes(projects.selectedBytes)). Projects always go to the Trash.")
            }
        } trailing: {
            if !projects.selectedBackableInFilter.isEmpty { backUpButton(projects.selectedBackableInFilter) }
            if !projects.trashCandidates.isEmpty, projects.selectedTrashable.count < projects.trashCandidates.count {
                Button("Select all safe") { projects.selectAllTrashable() }
            }
            Button { model.projects.showTrashSheet = true } label: { Text("Move \(projects.selectedTrashable.count) projects to Trash") }
                .buttonStyle(.kmPrimary)
                .disabled(projects.selectedTrashable.isEmpty)
                .accessibilityIdentifier("projects.trash")
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Check these folders")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            model.projects.roots = panel.urls.map { ($0.path as NSString).abbreviatingWithTildeInPath }
            Task { await model.projects.check() }
        }
    }
}

extension ProjectsModel.Filter {
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .safeToRemove: String(localized: "Safe to remove")
        case .notBackedUp: String(localized: "Not backed up")
        case .noGit: String(localized: "No git")
        case .keep: String(localized: "Keep")
        }
    }
}

extension ProjectScan {
    var sortRank: Int { verdict.rank }
    var sortLastChange: Date { lastChange ?? .distantPast }
    var sortBytes: Int64 { measure?.bytes ?? -1 }
}

private struct ProjectInspector: View {
    let project: ProjectScan
    let staleDays: Int
    let backUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: project.relativePath).font(.title3.weight(.semibold))
                StatusBadge(text: LocalizedStringKey(project.statusTitle), tone: project.statusTone)
            }
            let reasons = project.verdict.reasons
            if project.holdsRepositories, let explanation = project.embeddedExplanation {
                Text(verbatim: explanation).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
            } else if reasons.isEmpty {
                Text(verbatim: project.needsVerification
                     ? String(localized: "It looks safe from this Mac’s last fetch. Turn on Verify with GitHub to prove it before moving it to the Trash.")
                     : project.verdict.explanation)
                    .foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(reasons, id: \.self) { reason in
                        Label { Text(verbatim: reason.text).fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.kmWarning)
                        }
                    }
                }
                .font(.callout)
            }
            if !project.holdsRepositories, let explanation = project.embeddedExplanation {
                Text(verbatim: explanation).font(.callout).foregroundStyle(.kmWarning).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if let git = project.git {
                    GridRow { Text("Branch").foregroundStyle(.kmFgMuted); Text(verbatim: git.headBranch ?? String(localized: "None")) }
                    GridRow { Text("Branches").foregroundStyle(.kmFgMuted); Text("\(git.branches.count)") }
                    GridRow { Text("Last commit").foregroundStyle(.kmFgMuted); Text(git.lastCommitDate.map { Format.relative($0) } ?? String(localized: "None")) }
                }
                GridRow { Text("Newest file").foregroundStyle(.kmFgMuted); Text(project.measure?.newestModified.map { Format.relative($0) } ?? String(localized: "None")) }
                GridRow { Text("Size").foregroundStyle(.kmFgMuted); Text(project.measure.map { Format.bytes($0.bytes) } ?? "–") }
                GridRow { Text("GitHub").foregroundStyle(.kmFgMuted); Text(verbatim: project.githubText).lineLimit(2) }
            }
            .font(.callout)
            .tabular()
            if let git = project.git, git.ignoredCount > 0 {
                Text("Not in git, and would go to the Trash with the project: \(git.ignoredPaths.prefix(5).joined(separator: ", "))\(git.ignoredCount > 5 ? "…" : "")")
                    .font(.callout).foregroundStyle(.kmWarning).fixedSize(horizontal: false, vertical: true)
            }
            if let refusal = project.removalRefusal, project.verdict == .safeToRemove {
                Text("KeelMac won’t move it: \(String(localized: String.LocalizationValue(refusal.englishDescription)))")
                    .font(.callout).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
            }
            if project.canBackUp { Button("Back up…", action: backUp).buttonStyle(.kmPrimary) }
            if let url = project.githubURL { Button("Open on GitHub") { NSWorkspace.shared.open(url) } }
            Button("Reveal in Finder") { FileActions.reveal([project.path]) }
        }
    }
}
