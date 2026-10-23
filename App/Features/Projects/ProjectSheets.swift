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
