import Foundation
import SafetyKit

/// One step of a backup, shown to the person before anything runs.
public struct BackupStep: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Creates `.gitignore` (only when the folder has none) so generated folders and `.env` stay out of the commit.
        case writeGitignore
        case gitInit, gitAdd, gitCommit
        /// `gh repo view`: stops the backup when the name is already taken.
        case checkRepoName
        case createRepo
        case pushNewBranches, pushAll, pushTags
    }

    public let kind: Kind
    /// Empty for `writeGitignore`, which KeelMac does itself.
    public let executable: String
    /// For `writeGitignore`, the file path.
    public let arguments: [String]
    public let timeout: TimeInterval

    public init(kind: Kind, executable: String, arguments: [String], timeout: TimeInterval) {
        self.kind = kind; self.executable = executable; self.arguments = arguments; self.timeout = timeout
    }

    public var id: String { kind.rawValue }

    /// The exact command, or the file path for `writeGitignore`.
    public var commandLine: String {
        kind == .writeGitignore ? (arguments.first ?? "") : ProjectTools.commandLine(executable, arguments)
    }

    /// What `writeGitignore` writes.
    public static let gitignore = """
    # Written by KeelMac when it backed up this folder. Edit freely.
    .DS_Store
    node_modules/
    .build/
    build/
    DerivedData/
    Pods/
    dist/
    target/
    .venv/
    venv/
    __pycache__/
    .next/
    .env

    """
}

public struct BackupPlan: Sendable, Hashable {
    public let projectPath: String
    public let projectName: String
    public let steps: [BackupStep]
    /// "owner/name" of the GitHub repository the backup ends in.
    public let repository: String
    public let remoteName: String
    public let createsRepository: Bool
    public let commits: Bool
    /// Stashes can't be pushed; they stay on this Mac.
    public let stashesLeft: Int

    public var repositoryURL: URL? { URL(string: "https://github.com/\(repository)") }
}

public enum BackupPlanProblem: Error, Sendable, Hashable {
    /// Creating a repository needs a gh login.
    case githubUnavailable(GitHubAvailability)
    /// Pushing all branches wouldn't include the checked-out commit.
    case detachedHead
    /// A worktree's history lives in its main repository; back that one up.
    case linkedWorktree
    /// Nothing that a commit or a push would fix (for example only stashes, or GitHub is ahead).
    case nothingToBackUp
    case notAFolder
    case invalidRepositoryName
    /// The folder holds other git repositories (relative paths). `git add -A` would save each one as a bare pointer
    /// to a commit, without its files, and the backup would look complete when it isn't.
    case containsRepositories([String])
}

public enum BackupPlanner {
    /// The steps that put the project on GitHub. Pure: nothing runs here.
    public static func plan(for scan: ProjectScan, github: GitHubAvailability, commitMessage: String,
                            repositoryName: String? = nil, git: String = ProjectTools.git,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> Result<BackupPlan, BackupPlanProblem> {
        switch scan.verdict {
        case .symlink, .unreadable: return .failure(.notAFolder)
        case .linkedWorktree: return .failure(.linkedWorktree)
        default: break
        }
        let p = scan.path
        let state = scan.git
        if state?.isWorktree == true { return .failure(.linkedWorktree) }
        if !scan.embeddedRepositories.isEmpty { return .failure(.containsRepositories(scan.embeddedRepositories)) }
        if state?.isDetached == true { return .failure(.detachedHead) }

        var steps: [BackupStep] = []
        func gitStep(_ kind: BackupStep.Kind, _ args: [String], timeout: TimeInterval = 120) {
            steps.append(BackupStep(kind: kind, executable: git, arguments: ["-C", p] + args, timeout: timeout))
        }

        let isRepo = state != nil
        let needsCommit = isRepo ? (state!.uncommittedCount > 0) : ((scan.measure?.fileCount ?? 0) > 0)
        if !isRepo && !needsCommit { return .failure(.nothingToBackUp) }
        if isRepo && state!.hasCommits == false && !needsCommit { return .failure(.nothingToBackUp) }

        if !isRepo { gitStep(.gitInit, ["init", "-b", "main"]) }
        if needsCommit {
            if !fileExists(p + "/.gitignore") {
                steps.append(BackupStep(kind: .writeGitignore, executable: "", arguments: [p + "/.gitignore"], timeout: 5))
            }
            let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            gitStep(.gitAdd, ["add", "-A"], timeout: 300)
            gitStep(.gitCommit, ["commit", "-m", message.isEmpty ? "Backup from KeelMac" : message], timeout: 120)
        }

        let repository: String, remoteName: String, creates: Bool
        if let remote = state?.githubRemote, let ownerRepo = remote.ownerRepo {
            repository = ownerRepo; remoteName = remote.name; creates = false
            let reasons = scan.verdict.reasons
            let newBranches = reasons.compactMap { if case .branchNotPushed(let b) = $0 { b } else { nil } }
            let pushable = needsCommit || !newBranches.isEmpty || reasons.contains {
                switch $0 {
                case .unpushedCommits, .tagsNotOnGitHub: true
                default: false
                }
            }
            guard pushable else { return .failure(.nothingToBackUp) }
            if !newBranches.isEmpty { gitStep(.pushNewBranches, ["push", "--set-upstream", remoteName] + newBranches, timeout: 600) }
            gitStep(.pushAll, ["push", "--all", remoteName], timeout: 600)
            gitStep(.pushTags, ["push", "--tags", remoteName], timeout: 600)
        } else {
            guard case .available(let login, let gh) = github else { return .failure(.githubUnavailable(github)) }
            let name = repositoryName.map { $0.trimmingCharacters(in: .whitespaces) } ?? RepoSlug.make(scan.name)
            guard RepoSlug.isValid(name) else { return .failure(.invalidRepositoryName) }
            let hasOtherRemotes = !(state?.remotes.isEmpty ?? true)
            remoteName = state?.remotes.contains(where: { $0.name == "origin" }) == true ? "github" : "origin"
            repository = login + "/" + name; creates = true
            steps.append(BackupStep(kind: .checkRepoName, executable: gh, arguments: ["repo", "view", repository, "--json", "nameWithOwner"], timeout: 30))
            steps.append(BackupStep(kind: .createRepo, executable: gh,
                                    arguments: ["repo", "create", name, "--private", "--source", p, "--remote", remoteName], timeout: 120))
            // Only a repository's first remote becomes every branch's upstream.
            gitStep(.pushAll, ["push", "--all"] + (hasOtherRemotes ? [] : ["--set-upstream"]) + [remoteName], timeout: 600)
            gitStep(.pushTags, ["push", "--tags", remoteName], timeout: 600)
        }
        return .success(BackupPlan(projectPath: p, projectName: scan.name, steps: steps, repository: repository,
                                   remoteName: remoteName, createsRepository: creates, commits: needsCommit,
                                   stashesLeft: state?.stashCount ?? 0))
    }

    /// Paths of the projects in a batch that would create a repository another plan in the same batch also creates
    /// or pushes to. GitHub names ignore case. The second one would fail at `gh repo view`, so the batch shouldn't start.
    public static func projectsWithDuplicateRepository(in plans: [BackupPlan]) -> Set<String> {
        var count: [String: Int] = [:]
        for plan in plans { count[plan.repository.lowercased(), default: 0] += 1 }
        return Set(plans.filter { $0.createsRepository && count[$0.repository.lowercased(), default: 0] > 1 }.map(\.projectPath))
    }
}

public struct BackupStepOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case ran, failed(CommandFailure), skipped }
    public let step: BackupStep
    public let status: Status
    public let result: CommandResult?

    public init(step: BackupStep, status: Status, result: CommandResult?) { self.step = step; self.status = status; self.result = result }
}

public struct BackupResult: Sendable, Equatable {
    public let batchID: UUID
    public let outcomes: [BackupStepOutcome]

    public init(batchID: UUID, outcomes: [BackupStepOutcome]) { self.batchID = batchID; self.outcomes = outcomes }
    public var succeeded: Bool { outcomes.allSatisfy { $0.status == .ran } }
    public var failure: BackupStepOutcome? { outcomes.first { if case .failed = $0.status { true } else { false } } }
}

/// What a batch reports while it runs, one project at a time.
public enum BackupBatchEvent: Sendable, Equatable {
    case started(projectPath: String)
    case step(projectPath: String, BackupStepOutcome)
    case finished(projectPath: String, BackupResult)
    /// The person stopped the batch before this project.
    case notStarted(projectPath: String)
}

/// Every plan of a batch, in order, with its result; `nil` when the batch stopped before it.
public struct BackupBatchResult: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let plan: BackupPlan
        public let result: BackupResult?
        public init(plan: BackupPlan, result: BackupResult?) { self.plan = plan; self.result = result }
    }

    public let items: [Item]
    public init(items: [Item]) { self.items = items }

    public var succeeded: [Item] { items.filter { $0.result?.succeeded == true } }
    public var failed: [Item] { items.filter { $0.result?.failure != nil } }
    public var notStarted: [Item] { items.filter { $0.result == nil } }
}

/// Runs a plan's steps in order and stops at the first failure. Every step that runs is written to the operation log.
public struct BackupExecutor: Sendable {
    let runner: CommandRunning
    let log: OperationLogging
    let writeFile: @Sendable (String, String) throws -> Void

    public init(runner: CommandRunning, log: OperationLogging,
                writeFile: @escaping @Sendable (String, String) throws -> Void = BackupExecutor.createFile) {
        self.runner = runner; self.log = log; self.writeFile = writeFile
    }

    /// Writes the file only when nothing is there yet.
    public static let createFile: @Sendable (String, String) throws -> Void = { path, contents in
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    public func execute(_ plan: BackupPlan, title: String, onStep: (@Sendable (BackupStepOutcome) -> Void)? = nil) async -> BackupResult {
        let batch = UUID()
        var outcomes: [BackupStepOutcome] = []
        var stopped = false
        for step in plan.steps {
            if stopped {
                let outcome = BackupStepOutcome(step: step, status: .skipped, result: nil)
                outcomes.append(outcome); onStep?(outcome); continue
            }
            let outcome = await run(step)
            outcomes.append(outcome)
            onStep?(outcome)
            let reason: String? = if case .failed(let f) = outcome.status { Self.logReason(f, outcome.result) } else { nil }
            await log.record([OperationEntry(batchID: batch, kind: .projects, title: title, path: step.commandLine, bytes: 0,
                                             result: reason == nil ? .ran : .failed, reason: reason)])
            if case .failed = outcome.status { stopped = true }
        }
        return BackupResult(batchID: batch, outcomes: outcomes)
    }

    /// Runs several previewed plans one after the other. A failed project doesn't stop the others; each project keeps
    /// its own operation-log batch. `shouldStop` is asked between projects, never during one, so a push is never cut
    /// short; once it says yes, the rest are reported as `.notStarted`.
    public func execute(_ plans: [BackupPlan], title: @Sendable (BackupPlan) -> String,
                        shouldStop: @Sendable () async -> Bool = { false },
                        onEvent: (@Sendable (BackupBatchEvent) -> Void)? = nil) async -> BackupBatchResult {
        var items: [BackupBatchResult.Item] = []
        var stopped = false
        for plan in plans {
            if !stopped, await shouldStop() { stopped = true }
            if stopped {
                items.append(.init(plan: plan, result: nil))
                onEvent?(.notStarted(projectPath: plan.projectPath))
                continue
            }
            let path = plan.projectPath
            onEvent?(.started(projectPath: path))
            let result = await execute(plan, title: title(plan)) { onEvent?(.step(projectPath: path, $0)) }
            items.append(.init(plan: plan, result: result))
            onEvent?(.finished(projectPath: path, result))
        }
        return BackupBatchResult(items: items)
    }

    func run(_ step: BackupStep) async -> BackupStepOutcome {
        if step.kind == .writeGitignore {
            guard let path = step.arguments.first else { return BackupStepOutcome(step: step, status: .failed(.other(exit: 1, message: "")), result: nil) }
            if FileManager.default.fileExists(atPath: path) { return BackupStepOutcome(step: step, status: .ran, result: nil) }
            do {
                try writeFile(path, BackupStep.gitignore)
                return BackupStepOutcome(step: step, status: .ran, result: nil)
            } catch {
                return BackupStepOutcome(step: step, status: .failed(.other(exit: 1, message: (error as NSError).localizedDescription)), result: nil)
            }
        }
        let result = await runner.run(step.executable, step.arguments, timeout: step.timeout)
        if step.kind == .checkRepoName {
            if result.succeeded { return BackupStepOutcome(step: step, status: .failed(.repositoryExists(step.arguments[2])), result: result) }
            if GitHubParsers.isRepoNotFound(result.stderr) { return BackupStepOutcome(step: step, status: .ran, result: result) }
            return BackupStepOutcome(step: step, status: .failed(CommandFailure.classify(result)), result: result)
        }
        if step.kind == .createRepo && !result.succeeded && GitHubParsers.isNameTaken(result.stderr) {
            return BackupStepOutcome(step: step, status: .failed(.repositoryExists(step.arguments[2])), result: result)
        }
        return BackupStepOutcome(step: step, status: result.succeeded ? .ran : .failed(CommandFailure.classify(result)), result: result)
    }

    /// The tool's own words for the log (English, like the rest of the log's reasons).
    static func logReason(_ failure: CommandFailure, _ result: CommandResult?) -> String {
        switch failure {
        case .repositoryExists(let name): "Repository \(name) already exists"
        case .timedOut: "Timed out"
        case .other(_, let message) where !message.isEmpty: message
        default: CommandFailure.toolLine(result).isEmpty ? "Exit \(result?.exitCode ?? 1)" : CommandFailure.toolLine(result)
        }
    }
}
