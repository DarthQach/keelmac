import AppKit
import ProjectsKit
import SafetyKit
import SwiftUI

/// Preview before projects go to the Trash: each project, its size, and what isn't in git that goes with it.
struct ProjectTrashSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: [RemovalOutcome]?
    @State private var working = false
    @State private var chosen: [ProjectScan] = []

    private var total: Int64 { chosen.reduce(0) { $0 + ($1.measure?.bytes ?? 0) } }
    private var xcodeOpen: Bool {
        !VisualFixtures.enabled && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Move \(chosen.count) projects to the Trash?").font(.title3.weight(.semibold))
            if let outcome {
                result(outcome)
            } else {
                Text("Each one is on GitHub, checked against it just now, and unchanged for \(model.projects.staleDays) days. You can put them back from the Trash.")
                    .foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
                if xcodeOpen {
                    Text("Xcode is open. Close any of these projects there first.")
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.kmWarningSoft, in: RoundedRectangle(cornerRadius: 8))
                }
                List(chosen) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            FileIdentity(name: p.name, path: p.path, symbol: "folder.badge.gearshape")
                            Spacer()
                            Text(p.measure.map { Format.bytes($0.bytes) } ?? "–").tabular().foregroundStyle(.kmFgMuted)
                        }
                        if let git = p.git, git.ignoredCount > 0 {
                            Text("Not in git, goes to the Trash too: \(git.ignoredPaths.prefix(5).joined(separator: ", "))\(git.ignoredCount > 5 ? "…" : "")")
                                .font(.caption).foregroundStyle(.kmWarning)
                        }
                    }
                }
                .listStyle(.inset)
                .kmTableSurface()
                .frame(minHeight: 200)
                HStack {
                    Text("Projects always go to the Trash and are logged.").foregroundStyle(.kmFgMuted)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button { remove() } label: { Text("Move \(Format.bytes(total)) to Trash") }
                        .buttonStyle(.kmPrimary)
                        .disabled(chosen.isEmpty || working)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("projects.trash.confirm")
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(.kmBg)
        .onAppear { chosen = model.projects.selectedTrashable }
    }

    private func remove() {
        working = true
        Task {
            outcome = await model.projects.trash(chosen)
            working = false
            if VisualFixtures.enabled { dismiss() }
        }
    }

    @ViewBuilder private func result(_ out: [RemovalOutcome]) -> some View {
        Text("Moved \(Format.bytes(out.bytesRemoved)) to Trash.").tabular()
        ForEach(out.notRemoved) { o in
            HStack { PathText(path: o.path); Spacer(); Text(LocalizedStringKey(o.reason ?? "")).foregroundStyle(.kmWarning) }
        }
        HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.kmPrimary).keyboardShortcut(.defaultAction) }
    }
}

/// Back up: the exact commands, in order, before anything runs; then each step's result.
struct ProjectBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: ProjectScan

    @State private var availability: GitHubAvailability?
    @State private var message = String(localized: "Backup from KeelMac")
    @State private var repoName = ""
    @State private var statuses: [BackupStep.Kind: BackupStepOutcome] = [:]
    @State private var running = false
    @State private var result: BackupResult?

    private var needsGh: Bool { project.git?.githubRemote == nil }

    private var plan: Result<BackupPlan, BackupPlanProblem>? {
        guard let availability else { return nil }
        return BackupPlanner.plan(for: project, github: availability, commitMessage: message,
                                  repositoryName: repoName.isEmpty ? nil : repoName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Back up \(project.name)").font(.title3.weight(.semibold))
            switch plan {
            case nil:
                ProgressView("Asking gh who is signed in…").frame(maxWidth: .infinity, minHeight: 160)
            case .failure(let problem)?:
                Text(verbatim: problem.text).fixedSize(horizontal: false, vertical: true)
                if problem == .githubUnavailable(.notSignedIn) { CommandLabel(command: "gh auth login") }
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            case .success(let plan)?:
                details(plan)
            }
        }
        .padding(24)
        .frame(width: 680)
        .background(.kmBg)
        .task {
            if repoName.isEmpty { repoName = RepoSlug.make(project.name) }
            availability = needsGh ? await model.projects.availabilityForBackup() : .off
        }
    }

    @ViewBuilder private func details(_ plan: BackupPlan) -> some View {
        Text(plan.createsRepository
             ? "KeelMac creates the private repository \(plan.repository) and pushes every branch and tag to it."
             : "KeelMac pushes every branch and tag to \(plan.repository).")
            .foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
        if result == nil && !running {
            Form {
                if plan.commits { TextField("Commit message", text: $message) }
                if plan.createsRepository { TextField("Repository name", text: $repoName) }
            }
            .formStyle(.columns)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(plan.steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) { statusIcon(step); Text(verbatim: step.kind.title).fontWeight(.medium) }
                        CommandLabel(command: step.commandLine)
                        if step.kind == .writeGitignore {
                            DisclosureGroup("What it contains") {
                                Text(verbatim: BackupStep.gitignore).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 300)
        if plan.stashesLeft > 0 {
            Text("Stashes stay on this Mac: \(plan.stashesLeft). Apply or drop them to finish the backup.")
                .font(.callout).foregroundStyle(.kmWarning)
        }
        if let failure = result?.failure, case .failed(let reason) = failure.status {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: reason.text).foregroundStyle(.kmDanger).fixedSize(horizontal: false, vertical: true)
                if reason == .authentication { CommandLabel(command: "gh auth setup-git") }
                if let output = failure.result, !(output.stderr + output.stdout).isEmpty {
                    ScrollView {
                        Text(verbatim: (output.stderr + output.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
                }
            }
        } else if result?.succeeded == true {
            Text("Backed up to \(plan.repository).").foregroundStyle(.kmSuccess)
        }
        HStack {
            Text("These commands run in this order on your Mac, with your git and gh logins. KeelMac stores no token.")
                .font(.callout).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if result == nil {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                Button("Back up") { run(plan) }
                    .buttonStyle(.kmPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || (plan.createsRepository && !RepoSlug.isValid(repoName)))
                    .accessibilityIdentifier("projects.backup.run")
            } else {
                if result?.succeeded == true, let url = plan.repositoryURL { Button("Open on GitHub") { NSWorkspace.shared.open(url) } }
                Button("Done") { dismiss() }.buttonStyle(.kmPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func statusIcon(_ step: BackupStep) -> some View {
        switch statuses[step.kind]?.status {
        case .ran?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.kmSuccess)
        case .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.kmDanger)
        case .skipped?: Image(systemName: "minus.circle").foregroundStyle(.kmFgMuted)
        case nil:
            if running && statuses.count == (try? plan?.get().steps.firstIndex(of: step)) ?? -1 {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "circle").foregroundStyle(.kmFgMuted)
            }
        }
    }

    private func run(_ plan: BackupPlan) {
        running = true
        statuses = [:]
        Task {
            let outcome = await model.projects.backUp(plan) { step in
                Task { @MainActor in statuses[step.step.kind] = step }
            }
            running = false
            result = outcome ?? BackupResult(batchID: UUID(), outcomes: [])
        }
    }
}

/// Back up several projects: one preview of every repository and command, then one project at a time. A failed
/// project doesn't stop the others; Stop takes effect between projects, never in the middle of a push.
struct ProjectBulkBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let scan: ProjectScan
        let plan: BackupPlan
        /// False while the typed repository name isn't one GitHub accepts.
        let nameValid: Bool
        var id: String { scan.id }
    }

    private struct Skip: Identifiable {
        let scan: ProjectScan
        let problem: BackupPlanProblem
        var id: String { scan.id }
    }

    private enum Phase { case preview, running, done }

    @State private var availability: GitHubAvailability?
    @State private var message = String(localized: "Backup from KeelMac")
    @State private var repoNames: [String: String] = [:]
    @State private var phase: Phase = .preview
    /// The plans as they were when Back up was pressed; the preview isn't recomputed while they run.
    @State private var frozen: [Row]?
    @State private var current: String?
    @State private var stepsDone: [String: Int] = [:]
    @State private var results: [String: BackupResult] = [:]
    @State private var notStarted: Set<String> = []
    @State private var stop = StopFlag()
    @State private var stopping = false
    /// Rows whose commands are shown.
    @State private var expanded: Set<String> = []

    /// Set by `openBackup` before the sheet opens and unchanged while it's open (rechecks update `scans`, not this).
    private var chosen: [ProjectScan] { model.projects.bulkBackupChoice }

    private var login: String {
        if case .available(let login, _)? = availability { login } else { "" }
    }

    private func repoName(_ scan: ProjectScan) -> String {
        (repoNames[scan.id] ?? RepoSlug.make(scan.name)).trimmingCharacters(in: .whitespaces)
    }

    private var preview: (rows: [Row], skipped: [Skip]) {
        guard let availability else { return ([], []) }
        var rows: [Row] = [], skipped: [Skip] = []
        for scan in chosen {
            let name = repoName(scan)
            let valid = RepoSlug.isValid(name)
            // An invalid name keeps its row (so it can be fixed); Back up stays off until it's valid.
            switch BackupPlanner.plan(for: scan, github: availability, commitMessage: message, repositoryName: valid ? name : "repository") {
            case .success(let plan): rows.append(Row(scan: scan, plan: plan, nameValid: valid || !plan.createsRepository))
            case .failure(let problem): skipped.append(Skip(scan: scan, problem: problem))
            }
        }
        return (rows, skipped)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Back up \(chosen.count) projects").font(.title3.weight(.semibold))
            if availability == nil {
                ProgressView("Asking gh who is signed in…").frame(maxWidth: .infinity, minHeight: 160)
            } else {
                content
            }
        }
        .padding(24)
        .frame(width: 720)
        .background(.kmBg)
        .interactiveDismissDisabled(phase == .running)
        .task {
            let needsGh = chosen.contains { $0.git?.githubRemote == nil }
            availability = needsGh ? await model.projects.availabilityForBackup() : .off
        }
    }

    @ViewBuilder private var content: some View {
        let preview = self.preview
        let rows = frozen ?? preview.rows
        let duplicates = BackupPlanner.projectsWithDuplicateRepository(in: rows.map(\.plan))
        if !rows.isEmpty { summary(rows).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true) }
        if phase == .preview, rows.contains(where: \.plan.commits) {
            Form { TextField("Commit message", text: $message) }.formStyle(.columns)
        }
        if !rows.isEmpty {
            // A plain stack, not a List: a List hides the Commands disclosure triangles.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, r in
                        if index > 0 { Divider() }
                        row(r, duplicate: duplicates.contains(r.id)).padding(.horizontal, 14).padding(.vertical, 6)
                    }
                }
            }
            .kmTableSurface()
            .frame(minHeight: 240, maxHeight: 380)
        }
        if !preview.skipped.isEmpty { skippedList(preview.skipped) }
        let stashes = rows.reduce(0) { $0 + $1.plan.stashesLeft }
        if stashes > 0 {
            Text("Stashes stay on this Mac: \(stashes). Apply or drop them to finish the backup.")
                .font(.callout).foregroundStyle(.kmWarning)
        }
        if phase == .done {
            let succeeded = rows.filter { results[$0.id]?.succeeded == true }.count
            Text("Backed up \(succeeded) of \(rows.count).").tabular().fontWeight(.medium)
                .foregroundStyle(succeeded == rows.count ? Color.kmSuccess : Color.kmWarning)
        }
        footer(rows, canRun: !rows.isEmpty && rows.allSatisfy(\.nameValid) && duplicates.isEmpty)
    }

    private func summary(_ rows: [Row]) -> Text {
        let creates = rows.filter(\.plan.createsRepository).count
        let pushes = rows.count - creates
        if creates > 0 && pushes > 0 {
            return Text("KeelMac creates a private repository for \(creates) of them and pushes the rest to the repositories they already have on GitHub, one project at a time.")
        } else if creates > 0 {
            return Text("KeelMac creates a private repository for each one and pushes every branch and tag to it, one project at a time.")
        }
        return Text("KeelMac pushes every branch and tag of each one to the repository it already has on GitHub, one project at a time.")
    }

    // MARK: Rows

    private func row(_ row: Row, duplicate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                status(row).frame(width: 18)
                Text(verbatim: row.scan.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(row.scan.measure.map { Format.bytes($0.bytes) } ?? "–").tabular().foregroundStyle(.kmFgMuted)
            }
            Group {
                if row.plan.createsRepository && phase == .preview {
                    HStack(spacing: 4) {
                        Text(verbatim: login + "/").foregroundStyle(.kmFgMuted)
                        TextField("Repository name", text: nameBinding(row.scan))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        Text("New private repository").foregroundStyle(.kmFgMuted)
                    }
                    if !row.nameValid {
                        Text(verbatim: BackupPlanProblem.invalidRepositoryName.text).foregroundStyle(.kmWarning)
                    } else if duplicate {
                        Text("Another project here would create \(row.plan.repository) too. Give one of them another name.")
                            .foregroundStyle(.kmWarning)
                    }
                } else if row.plan.createsRepository {
                    Text("New private repository \(row.plan.repository)").foregroundStyle(.kmFgMuted)
                } else {
                    Text("Pushes to \(row.plan.repository)").foregroundStyle(.kmFgMuted)
                }
                detail(row)
                // A button rather than a DisclosureGroup, so the whole label opens it, not only the small triangle.
                let open = expanded.contains(row.id)
                Button {
                    if open { expanded.remove(row.id) } else { expanded.insert(row.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(open ? 90 : 0))
                        Text("Commands")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("projects.backup.bulk.commands")
                .accessibilityValue(open ? Text("Shown") : Text("Hidden"))
                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(row.plan.steps) { step in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: step.kind.title)
                                CommandLabel(command: step.commandLine)
                                if step.kind == .writeGitignore {
                                    DisclosureGroup("What it contains") {
                                        Text(verbatim: BackupStep.gitignore).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.leading, 18)
                }
            }
            .font(.callout)
            .padding(.leading, 28)
        }
        .padding(.vertical, 4)
    }

    private func nameBinding(_ scan: ProjectScan) -> Binding<String> {
        Binding(get: { repoNames[scan.id] ?? RepoSlug.make(scan.name) }, set: { repoNames[scan.id] = $0 })
    }

    @ViewBuilder private func status(_ row: Row) -> some View {
        if let result = results[row.id] {
            if result.succeeded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.kmSuccess)
            } else {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.kmDanger)
            }
        } else if notStarted.contains(row.id) {
            Image(systemName: "minus.circle").foregroundStyle(.kmFgMuted)
        } else if current == row.id {
            ProgressView().controlSize(.small)
        } else if phase == .preview {
            Image(systemName: row.scan.verdict == .noGit ? "folder" : "folder.badge.gearshape").foregroundStyle(.kmFgMuted)
        } else {
            Image(systemName: "circle").foregroundStyle(.kmFgMuted)
        }
    }

    @ViewBuilder private func detail(_ row: Row) -> some View {
        if let failure = results[row.id]?.failure, case .failed(let reason) = failure.status {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: failure.step.kind.title + ": " + reason.text).foregroundStyle(.kmDanger)
                    .fixedSize(horizontal: false, vertical: true)
                if reason == .authentication { CommandLabel(command: "gh auth setup-git") }
                if let output = failure.result, !(output.stderr + output.stdout).isEmpty {
                    DisclosureGroup("Tool output") {
                        Text(verbatim: (output.stderr + output.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else if results[row.id]?.succeeded == true, let url = row.plan.repositoryURL {
            Button("Open on GitHub") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
        } else if notStarted.contains(row.id) {
            Text("Not started").foregroundStyle(.kmFgMuted)
        } else if current == row.id {
            let done = min(stepsDone[row.id] ?? 0, row.plan.steps.count - 1)
            Text("Step \(done + 1) of \(row.plan.steps.count): \(row.plan.steps[done].kind.title)").tabular().foregroundStyle(.kmFgMuted)
        }
    }

    private func skippedList(_ skipped: [Skip]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Can’t be backed up from here: \(skipped.count)").font(.headline).tabular()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(skipped) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: s.scan.name).fontWeight(.medium)
                            Text(verbatim: s.problem.text).font(.callout).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 120)
            if skipped.contains(where: { $0.problem == .githubUnavailable(.notSignedIn) }) { CommandLabel(command: "gh auth login") }
        }
    }

    // MARK: Footer

    @ViewBuilder private func footer(_ rows: [Row], canRun: Bool) -> some View {
        HStack {
            if phase == .running, let index = rows.firstIndex(where: { $0.id == current }) {
                Text("Backing up \(index + 1) of \(rows.count)…").tabular().foregroundStyle(.kmFgMuted)
            } else {
                Text("These commands run in this order on your Mac, with your git and gh logins. KeelMac stores no token.")
                    .font(.callout).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch phase {
            case .preview where rows.isEmpty:
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            case .preview:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { run(rows) } label: { rows.count > 1 ? Text("Back up \(rows.count) projects") : Text("Back up") }
                    .buttonStyle(.kmPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
                    .accessibilityIdentifier("projects.backup.bulk.run")
            case .running:
                Button { stop.set(); stopping = true } label: {
                    stopping ? Text("Stopping after this project…") : Text("Stop after this project")
                }
                .disabled(stopping)
            case .done:
                Button("View in operation log") { model.route = .operationLog; dismiss() }
                Button("Done") { dismiss() }.buttonStyle(.kmPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func run(_ rows: [Row]) {
        frozen = rows
        phase = .running
        let plans = rows.map(\.plan)
        let stop = self.stop
        Task {
            let outcome = await model.projects.backUp(plans, shouldStop: { stop.isSet }) { event in
                Task { @MainActor in apply(event) }
            }
            guard let outcome else { dismiss(); return }   // visual fixtures run nothing
            // The batch's own answer wins over events that may still be queued.
            for item in outcome.items {
                if let result = item.result { results[item.plan.projectPath] = result } else { notStarted.insert(item.plan.projectPath) }
            }
            current = nil
            phase = .done
        }
    }

    private func apply(_ event: BackupBatchEvent) {
        switch event {
        case .started(let path): current = path; stepsDone[path] = 0
        case .step(let path, _): stepsDone[path, default: 0] += 1
        case .finished(let path, let result):
            results[path] = result
            if current == path { current = nil }
        case .notStarted(let path): notStarted.insert(path)
        }
    }
}

/// Set from the main actor, read by the batch between projects.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
