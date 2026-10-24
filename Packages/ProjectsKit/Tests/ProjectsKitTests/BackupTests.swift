import Foundation
import Testing
import SafetyKit
@testable import ProjectsKit

@Suite("Backup planner")
struct BackupPlannerTests {
    let gh = "/opt/homebrew/bin/gh"
    var signedIn: GitHubAvailability { .available(login: "demo", gh: gh) }
    let github = RemoteInfo(name: "origin", url: "https://github.com/demo/app.git", ownerRepo: "demo/app")

    func scan(git: GitState?, verdict: ProjectVerdict, files: Int = 3, name: String = "My App") -> ProjectScan {
        ProjectScan(path: "/Users/me/Developer/\(name)", name: name, root: "/Users/me/Developer", git: git, github: .off,
                    measure: FolderMeasure(bytes: 100, fileCount: files, newestModified: nil, ownModified: nil, unreadable: 0),
                    lastChange: nil, isStale: false, verdict: verdict, removalRefusal: nil, scannedAt: Date())
    }

    func repo(remotes: [RemoteInfo], uncommitted: Int = 0, stashes: Int = 0, head: String? = "main") -> GitState {
        GitState(headBranch: head, headSHA: "a", hasCommits: true, uncommittedCount: uncommitted, stashCount: stashes,
                 branches: [BranchInfo(name: "main", sha: "a", upstream: remotes.isEmpty ? nil : "origin/main")],
                 remotes: remotes, lastCommitDate: nil)
    }

    func kinds(_ result: Result<BackupPlan, BackupPlanProblem>) -> [BackupStep.Kind] {
        (try? result.get().steps.map(\.kind)) ?? []
    }

    @Test func folderWithoutGitBecomesAPrivateRepository() throws {
        let result = BackupPlanner.plan(for: scan(git: nil, verdict: .noGit), github: signedIn, commitMessage: "First backup",
                                        fileExists: { _ in false })
        let plan = try result.get()
        #expect(plan.steps.map(\.kind) == [.gitInit, .writeGitignore, .gitAdd, .gitCommit, .checkRepoName, .createRepo, .pushAll, .pushTags])
        #expect(plan.repository == "demo/My-App")
        #expect(plan.createsRepository && plan.commits)
        let p = "/Users/me/Developer/My App"
        #expect(plan.steps[0].arguments == ["-C", p, "init", "-b", "main"])
        #expect(plan.steps[1].arguments == [p + "/.gitignore"])
        #expect(plan.steps[3].arguments == ["-C", p, "commit", "-m", "First backup"])
        #expect(plan.steps[4].executable == gh && plan.steps[4].arguments == ["repo", "view", "demo/My-App", "--json", "nameWithOwner"])
        #expect(plan.steps[5].arguments == ["repo", "create", "My-App", "--private", "--source", p, "--remote", "origin"])
        #expect(plan.steps[6].arguments == ["-C", p, "push", "--all", "--set-upstream", "origin"])
        #expect(plan.steps[7].arguments == ["-C", p, "push", "--tags", "origin"])
        #expect(plan.steps.filter { $0.executable == ProjectTools.git }.allSatisfy { $0.arguments.prefix(2) == ["-C", p] })
    }

    @Test func existingGitignoreIsKeptAndMessageDefaults() throws {
        let plan = try BackupPlanner.plan(for: scan(git: nil, verdict: .noGit), github: signedIn, commitMessage: "  ",
                                          fileExists: { _ in true }).get()
        #expect(!plan.steps.contains { $0.kind == .writeGitignore })
        #expect(plan.steps.first { $0.kind == .gitCommit }?.arguments.last == "Backup from KeelMac")
    }

    @Test func emptyFolderHasNothingToBackUp() {
        #expect(BackupPlanner.plan(for: scan(git: nil, verdict: .noGit, files: 0), github: signedIn, commitMessage: "x") == .failure(.nothingToBackUp))
    }

    @Test func uncommittedWorkOnGitHubRemote() throws {
        let s = scan(git: repo(remotes: [github], uncommitted: 2), verdict: .notBackedUp([.uncommittedChanges(2)]))
        let plan = try BackupPlanner.plan(for: s, github: .off, commitMessage: "wip", fileExists: { _ in true }).get()
        #expect(plan.steps.map(\.kind) == [.gitAdd, .gitCommit, .pushAll, .pushTags])
        #expect(plan.repository == "demo/app" && !plan.createsRepository)
    }

    @Test func newBranchesGetAnUpstream() throws {
        let s = scan(git: repo(remotes: [github]), verdict: .notBackedUp([.branchNotPushed("feat"), .branchNotPushed("spike")]))
        let plan = try BackupPlanner.plan(for: s, github: .off, commitMessage: "x").get()
        #expect(plan.steps.map(\.kind) == [.pushNewBranches, .pushAll, .pushTags])
        #expect(plan.steps[0].arguments.suffix(4) == ["--set-upstream", "origin", "feat", "spike"])
    }

    @Test func stashesAloneCantBeBackedUp() {
        let s = scan(git: repo(remotes: [github], stashes: 2), verdict: .notBackedUp([.stashes(2)]))
        #expect(BackupPlanner.plan(for: s, github: signedIn, commitMessage: "x") == .failure(.nothingToBackUp))
    }

    @Test func noRemoteNeedsGh() throws {
        let s = scan(git: repo(remotes: []), verdict: .notBackedUp([.noRemote]))
        #expect(BackupPlanner.plan(for: s, github: .ghMissing, commitMessage: "x") == .failure(.githubUnavailable(.ghMissing)))
        let plan = try BackupPlanner.plan(for: s, github: signedIn, commitMessage: "x").get()
        #expect(plan.steps.map(\.kind) == [.checkRepoName, .createRepo, .pushAll, .pushTags])
        #expect(plan.stashesLeft == 0)
    }

    @Test func otherOriginGetsAGitHubRemoteBesideIt() throws {
        let lab = RemoteInfo(name: "origin", url: "git@gitlab.com:me/app.git", ownerRepo: nil)
        let s = scan(git: repo(remotes: [lab]), verdict: .notBackedUp([.remoteNotGitHub("origin")]))
        let plan = try BackupPlanner.plan(for: s, github: signedIn, commitMessage: "x", repositoryName: "app-mirror").get()
        #expect(plan.remoteName == "github")
        #expect(plan.repository == "demo/app-mirror")
        #expect(plan.steps.first { $0.kind == .createRepo }?.arguments.suffix(2) == ["--remote", "github"])
        #expect(plan.steps.first { $0.kind == .pushAll }?.arguments.suffix(3) == ["push", "--all", "github"])   // origin keeps its upstreams
    }

    @Test func refusals() {
        #expect(BackupPlanner.plan(for: scan(git: repo(remotes: [github], head: nil), verdict: .notBackedUp([.detachedHead])),
                                   github: signedIn, commitMessage: "x") == .failure(.detachedHead))
        var wt = repo(remotes: [github]); wt.isWorktree = true
        #expect(BackupPlanner.plan(for: scan(git: wt, verdict: .linkedWorktree), github: signedIn, commitMessage: "x") == .failure(.linkedWorktree))
        #expect(BackupPlanner.plan(for: scan(git: nil, verdict: .symlink), github: signedIn, commitMessage: "x") == .failure(.notAFolder))
        #expect(BackupPlanner.plan(for: scan(git: nil, verdict: .noGit), github: signedIn, commitMessage: "x", repositoryName: "bad name")
                == .failure(.invalidRepositoryName))
    }
}

@Suite("Backup executor")
struct BackupExecutorTests {
    let gh = "/opt/homebrew/bin/gh"

    func plan(_ path: String = "/tmp/x") -> BackupPlan {
        let scan = ProjectScan(path: path, name: "x", root: "/tmp", git: nil, github: .notApplicable,
                               measure: FolderMeasure(bytes: 1, fileCount: 1, newestModified: nil, ownModified: nil, unreadable: 0),
                               lastChange: nil, isStale: false, verdict: .noGit, removalRefusal: nil, scannedAt: Date())
        return try! BackupPlanner.plan(for: scan, github: .available(login: "demo", gh: gh), commitMessage: "m",
                                       fileExists: { _ in true }).get()
    }

    @Test func runsEveryStepAndLogsEach() async {
        let runner = RecordingCommandRunner { exe, args in
            if args.starts(with: ["repo", "view"]) {
                return CommandResult(exitCode: 1, stdout: "", stderr: "GraphQL: Could not resolve to a Repository with the name 'demo/x'.")
            }
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let log = InMemoryOperationLog()
        let p = plan()
        let result = await BackupExecutor(runner: runner, log: log).execute(p, title: "Back up x")
        #expect(result.succeeded)
        #expect(runner.calls.count == p.steps.count)
        let entries = await log.entries
        #expect(entries.count == p.steps.count)
        #expect(entries.allSatisfy { $0.kind == .projects && $0.result == .ran && $0.title == "Back up x" })
        #expect(Set(entries.map(\.batchID)).count == 1)
        #expect(entries.map(\.path) == p.steps.map(\.commandLine))
    }

    @Test func takenNameStopsBeforeCreating() async {
        let runner = RecordingCommandRunner { _, args in
            CommandResult(exitCode: 0, stdout: args.starts(with: ["repo", "view"]) ? "{\"nameWithOwner\":\"demo/x\"}" : "", stderr: "")
        }
        let log = InMemoryOperationLog()
        var seen: [BackupStepOutcome.Status] = []
        let collector = Collector()
        let result = await BackupExecutor(runner: runner, log: log).execute(plan(), title: "t") { collector.add($0.status) }
        seen = collector.all
        #expect(!result.succeeded)
        #expect(result.failure?.status == .failed(.repositoryExists("demo/x")))
        #expect(!runner.calls.contains { $0.1.starts(with: ["repo", "create"]) })
        #expect(seen.filter { $0 == .skipped }.count == 3)   // create, push all, push tags
        let entries = await log.entries
        #expect(entries.last?.result == .failed)
        #expect(entries.last?.reason == "Repository demo/x already exists")
    }

    @Test func pushFailureIsClassified() async {
        let runner = RecordingCommandRunner { _, args in
            if args.starts(with: ["repo", "view"]) { return CommandResult(exitCode: 1, stdout: "", stderr: "Could not resolve to a Repository") }
            if args.contains("push") { return CommandResult(exitCode: 128, stdout: "", stderr: "fatal: could not read Username for 'https://github.com': Device not configured") }
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let result = await BackupExecutor(runner: runner, log: InMemoryOperationLog()).execute(plan(), title: "t")
        #expect(result.failure?.step.kind == .pushAll)
        #expect(result.failure?.status == .failed(.authentication))
    }

    @Test func gitignoreIsWrittenOnlyWhenMissing() async throws {
        let fx = Fixture()
        let folder = fx.dir("home/Developer/x")
        let step = BackupStep(kind: .writeGitignore, executable: "", arguments: [folder + "/.gitignore"], timeout: 5)
        let p = BackupPlan(projectPath: folder, projectName: "x", steps: [step], repository: "demo/x", remoteName: "origin",
                           createsRepository: false, commits: true, stashesLeft: 0)
        let executor = BackupExecutor(runner: RecordingCommandRunner(), log: InMemoryOperationLog())
        #expect(await executor.execute(p, title: "t").succeeded)
        #expect(try String(contentsOfFile: folder + "/.gitignore", encoding: .utf8) == BackupStep.gitignore)
        try "mine\n".write(toFile: folder + "/.gitignore", atomically: true, encoding: .utf8)
        #expect(await executor.execute(p, title: "t").succeeded)
        #expect(try String(contentsOfFile: folder + "/.gitignore", encoding: .utf8) == "mine\n")
    }

    /// The whole flow with real git: a folder without git ends up on "GitHub" (a bare repository) and checks clean.
    @Test func backUpThenCheckAgain() async throws {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let bare = fx.bare("remotes/sketch.git")
        let folder = fx.dir("home/Developer/sketch")
        fx.file("home/Developer/sketch/index.html", bytes: 200)
        fx.file("home/Developer/sketch/node_modules/dep/i.js", bytes: 200)
        runner.remotes["origin"] = bare
        runner.gh = { args in
            if args.starts(with: ["repo", "view"]) { return CommandResult(exitCode: 1, stdout: "", stderr: "Could not resolve to a Repository") }
            if args.starts(with: ["repo", "create"]) {
                // What gh does with --source and --remote: add the remote.
                return fx.git(["remote", "add", "origin", "https://github.com/demo/sketch.git"], in: folder)
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
        let scanner = ProjectScanner(runner: runner, pathGuard: fx.pathGuard, gh: gh)
        let entry = ProjectEntry(root: fx.developer, path: folder, kind: .directory)
        let before = await scanner.scan(entry, options: ProjectScanOptions(verifyWithGitHub: true))
        #expect(before.verdict == .noGit)

        let plan = try BackupPlanner.plan(for: before, github: .available(login: "demo", gh: gh), commitMessage: "Backup").get()
        let result = await BackupExecutor(runner: runner, log: InMemoryOperationLog()).execute(plan, title: "Back up sketch")
        #expect(result.succeeded, "\(String(describing: result.failure))")

        let after = await scanner.scan(entry, options: ProjectScanOptions(verifyWithGitHub: true))
        #expect(after.github == .checked)
        #expect(after.verdict == .keep, "\(after.verdict)")
        let files = fx.git(["ls-tree", "-r", "--name-only", "main"], in: bare).stdout
        #expect(files.contains("index.html") && files.contains(".gitignore") && !files.contains("node_modules"))
    }
}

@Suite("Backup batch")
struct BackupBatchTests {
    let gh = "/opt/homebrew/bin/gh"

    func plan(_ name: String) -> BackupPlan {
        let scan = ProjectScan(path: "/tmp/\(name)", name: name, root: "/tmp", git: nil, github: .notApplicable,
                               measure: FolderMeasure(bytes: 1, fileCount: 1, newestModified: nil, ownModified: nil, unreadable: 0),
                               lastChange: nil, isStale: false, verdict: .noGit, removalRefusal: nil, scannedAt: Date())
        return try! BackupPlanner.plan(for: scan, github: .available(login: "demo", gh: gh), commitMessage: "m",
                                       fileExists: { _ in true }).get()
    }

    /// Succeeds everywhere except a push from a folder listed in `failPushIn`.
    func runner(failPushIn: Set<String> = []) -> RecordingCommandRunner {
        RecordingCommandRunner { _, args in
            if args.starts(with: ["repo", "view"]) { return CommandResult(exitCode: 1, stdout: "", stderr: "Could not resolve to a Repository") }
            if args.contains("push"), args.count > 1, failPushIn.contains(args[1]) {
                return CommandResult(exitCode: 1, stdout: "", stderr: "fatal: unable to access: Could not resolve host: github.com")
            }
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    @Test func runsEachProjectInOrderWithItsOwnLogBatch() async {
        let a = plan("a"), b = plan("b")
        let runner = runner()
        let log = InMemoryOperationLog()
        let events = EventCollector()
        let result = await BackupExecutor(runner: runner, log: log)
            .execute([a, b], title: { "Back up \($0.projectName)" }, onEvent: { events.add($0) })
        #expect(result.succeeded.map(\.plan) == [a, b])
        #expect(result.failed.isEmpty && result.notStarted.isEmpty)
        // Every command of a runs before any command of b.
        let folders = runner.calls.compactMap { call in ["/tmp/a", "/tmp/b"].first { call.1.contains($0) } }
        #expect(folders == folders.sorted() && Set(folders) == ["/tmp/a", "/tmp/b"])
        let entries = await log.entries
        #expect(Set(entries.map(\.batchID)).count == 2)
        #expect(Set(entries.filter { $0.title == "Back up a" }.map(\.batchID)).count == 1)
        let all = events.all
        #expect(all.first == .started(projectPath: "/tmp/a"))
        #expect(all.filter { if case .step = $0 { true } else { false } }.count == a.steps.count + b.steps.count)
        if case .finished(let path, let r)? = all.last { #expect(path == "/tmp/b" && r.succeeded) } else { Issue.record("no finish") }
    }

    @Test func aFailedProjectDoesNotStopTheNext() async {
        let a = plan("a"), b = plan("b")
        let result = await BackupExecutor(runner: runner(failPushIn: ["/tmp/a"]), log: InMemoryOperationLog())
            .execute([a, b], title: { $0.projectName })
        #expect(result.failed.map(\.plan) == [a])
        #expect(result.failed.first?.result?.failure?.status == .failed(.offline))
        #expect(result.succeeded.map(\.plan) == [b])
    }

    @Test func stopsBetweenProjectsNeverDuringOne() async {
        let a = plan("a"), b = plan("b"), c = plan("c")
        let runner = runner()
        let events = EventCollector()
        let result = await BackupExecutor(runner: runner, log: InMemoryOperationLog())
            .execute([a, b, c], title: { $0.projectName },
                     shouldStop: { events.all.contains { if case .finished = $0 { true } else { false } } },
                     onEvent: { events.add($0) })
        #expect(result.succeeded.map(\.plan) == [a])
        #expect(result.notStarted.map(\.plan) == [b, c])
        #expect(runner.calls.count == a.steps.count)
        #expect(events.all.suffix(2) == [.notStarted(projectPath: "/tmp/b"), .notStarted(projectPath: "/tmp/c")])
    }

    @Test func flagsProjectsThatWouldCreateTheSameRepository() {
        let first = plan("My App"), second = plan("my-app"), other = plan("other")
        #expect(first.repository == "demo/My-App" && second.repository == "demo/my-app")
        #expect(BackupPlanner.projectsWithDuplicateRepository(in: [first, second, other]) == ["/tmp/My App", "/tmp/my-app"])
        // Pushing to an existing repository isn't the problem; creating one with its name is.
        let existing = BackupPlan(projectPath: "/tmp/old", projectName: "old", steps: [], repository: "demo/other", remoteName: "origin",
                                  createsRepository: false, commits: false, stashesLeft: 0)
        #expect(BackupPlanner.projectsWithDuplicateRepository(in: [existing, other]) == ["/tmp/other"])
        #expect(BackupPlanner.projectsWithDuplicateRepository(in: [first, other]).isEmpty)
    }

    /// Two real folders in one batch: one without git, one whose only remote isn't GitHub (so it gets a `github`
    /// remote). Each ends up in its own bare "GitHub" repository.
    @Test func backsUpTwoFoldersWithRealGit() async throws {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let sketchBare = fx.bare("remotes/sketch.git"), notesBare = fx.bare("remotes/notes.git")
        let sketch = fx.dir("home/Developer/sketch")
        fx.file("home/Developer/sketch/index.html", bytes: 200)
        let notes = fx.repo("home/Developer/notes")
        fx.git(["remote", "add", "origin", fx.dir("elsewhere/notes.git")], in: notes)
        runner.remotes = ["origin": sketchBare, "github": notesBare]
        runner.gh = { args in
            if args.starts(with: ["repo", "view"]) { return CommandResult(exitCode: 1, stdout: "", stderr: "Could not resolve to a Repository") }
            if args.starts(with: ["repo", "create"]), let source = args.firstIndex(of: "--source"), let remote = args.firstIndex(of: "--remote") {
                return fx.git(["remote", "add", args[remote + 1], "https://github.com/demo/\(args[2]).git"], in: args[source + 1])
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
        let scanner = ProjectScanner(runner: runner, pathGuard: fx.pathGuard, gh: gh)
        let github = GitHubAvailability.available(login: "demo", gh: gh)
        var plans: [BackupPlan] = []
        for folder in [sketch, notes] {
            let scan = await scanner.scan(ProjectEntry(root: fx.developer, path: folder, kind: .directory), options: ProjectScanOptions())
            plans.append(try BackupPlanner.plan(for: scan, github: github, commitMessage: "Backup").get())
        }
        #expect(plans.map(\.remoteName) == ["origin", "github"])
        #expect(BackupPlanner.projectsWithDuplicateRepository(in: plans).isEmpty)

        let result = await BackupExecutor(runner: runner, log: InMemoryOperationLog()).execute(plans, title: { $0.projectName })
        #expect(result.succeeded.count == 2, "\(result.failed.map { String(describing: $0.result?.failure) })")
        #expect(fx.git(["ls-tree", "-r", "--name-only", "main"], in: sketchBare).stdout.contains("index.html"))
        #expect(fx.git(["ls-tree", "-r", "--name-only", "main"], in: notesBare).stdout.contains("README.md"))
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BackupBatchEvent] = []
    func add(_ e: BackupBatchEvent) { lock.withLock { items.append(e) } }
    var all: [BackupBatchEvent] { lock.withLock { items } }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BackupStepOutcome.Status] = []
    func add(_ s: BackupStepOutcome.Status) { lock.withLock { items.append(s) } }
    var all: [BackupStepOutcome.Status] { lock.withLock { items } }
}
