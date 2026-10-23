import Foundation
import Testing
import SafetyKit
@testable import ProjectsKit

@Suite("Project scanner")
struct ScannerTests {
    let now = Date()

    func scanner(_ fx: Fixture, _ runner: FixtureRunner, gh: String? = nil) -> ProjectScanner {
        ProjectScanner(runner: runner, pathGuard: fx.pathGuard, gh: gh)
    }

    func options(verify: Bool) -> ProjectScanOptions { ProjectScanOptions(staleAfterDays: 180, verifyWithGitHub: verify, now: now) }

    func entry(_ fx: Fixture, _ name: String) -> ProjectEntry { ProjectEntry(root: fx.developer, path: fx.developer + "/" + name, kind: .directory) }

    /// A repository on "GitHub" (a local bare repository), committed and untouched for 200 days.
    func oldPublishedRepo(_ fx: Fixture, _ runner: FixtureRunner, name: String = "old") -> String {
        let old = Date.daysAgo(200, from: now)
        let repo = fx.repo("home/Developer/\(name)", committed: old)
        let bare = fx.bare("remotes/\(name).git")
        fx.publish(repo, to: bare, as: "demo/\(name)")
        fx.age(repo, to: old)
        runner.remotes["origin"] = bare
        return repo
    }

    // MARK: - Listing

    @Test func listsDirectSubfoldersOnly() throws {
        let fx = Fixture()
        fx.dir("home/Developer/b-app")
        fx.dir("home/Developer/A-tool/nested")
        fx.dir("home/Developer/.hidden")
        fx.file("home/Developer/notes.txt")
        fx.dir("elsewhere/real")
        try FileManager.default.createSymbolicLink(atPath: fx.developer + "/linked", withDestinationPath: fx.path("elsewhere/real"))
        let listing = scanner(fx, FixtureRunner(fx)).listProjects(in: [fx.developer, fx.path("missing")])
        #expect(listing.entries.map(\.name) == ["A-tool", "b-app", "linked"])
        #expect(listing.entries.last?.kind == .symlink)
        #expect(listing.unreadableRoots == [fx.path("missing")])
    }

    @Test func tildeRootsExpandAgainstTheGuardsHome() {
        let fx = Fixture()
        fx.dir("home/Developer/app")
        let listing = scanner(fx, FixtureRunner(fx)).listProjects(in: ["~/Developer"])
        #expect(listing.entries.map(\.path) == [fx.developer + "/app"])
    }

    // MARK: - Verdicts

    @Test func folderWithoutGit() async {
        let fx = Fixture()
        fx.file("home/Developer/sketch/index.html", modified: Date.daysAgo(400, from: now))
        let runner = FixtureRunner(fx)
        let scan = await scanner(fx, runner).scan(entry(fx, "sketch"), options: options(verify: true))
        #expect(scan.verdict == .noGit)
        #expect(scan.isStale)
        #expect(scan.github == .notApplicable)
        #expect(runner.calls.isEmpty)   // no .git: git never runs
    }

    @Test func rootThatIsARepoDoesNotLeakIntoSubfolders() async {
        let fx = Fixture()
        fx.repo("home/Developer")   // the root itself is a repository
        fx.file("home/Developer/plain/a.txt")
        let scan = await scanner(fx, FixtureRunner(fx)).scan(entry(fx, "plain"), options: options(verify: false))
        #expect(scan.verdict == .noGit)
    }

    @Test func oldPushedVerifiedRepoIsATrashCandidate() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        _ = oldPublishedRepo(fx, runner)
        let scan = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: true))
        #expect(scan.verdict == .safeToRemove, "\(scan.verdict)")
        #expect(scan.github == .checked)
        #expect(scan.isTrashCandidate)
        #expect(scan.githubURL?.absoluteString == "https://github.com/demo/old")
        #expect(scan.removalRefusal == nil)
        #expect(scan.git?.lastCommitDate.map { abs($0.timeIntervalSince(Date.daysAgo(200, from: now))) < 5 } == true)
        #expect(scan.measure?.bytes ?? 0 > 0)
    }

    @Test func withoutVerificationItIsOnlyProbablySafe() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        _ = oldPublishedRepo(fx, runner)
        let scan = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: false))
        #expect(scan.verdict == .safeToRemove)
        #expect(scan.github == .off)
        #expect(!scan.isTrashCandidate)
        #expect(scan.needsVerification)
        #expect(!runner.gitCalls.contains { $0.contains("ls-remote") })
    }

    @Test func recentFileKeepsAnOldRepo() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let repo = oldPublishedRepo(fx, runner)
        fx.setModified(repo + "/README.md", Date.daysAgo(3, from: now))   // touched, content unchanged
        let scan = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: true))
        #expect(scan.verdict == .keep)
        #expect(!scan.isStale)
    }

    @Test func recentCommitKeepsARepo() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let repo = oldPublishedRepo(fx, runner)
        fx.commit(repo, file: "new.txt", date: Date.daysAgo(5, from: now))
        fx.git(["push", "-q", runner.remotes["origin"]!, "main"], in: repo)
        fx.age(repo, to: Date.daysAgo(200, from: now))
        let scan = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: true))
        #expect(scan.verdict == .keep, "\(scan.verdict)")
    }

    @Test func localWorkIsListedWithoutNetwork() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let repo = oldPublishedRepo(fx, runner)
        fx.commit(repo, file: "ahead.txt")                       // main is one commit ahead of origin/main
        fx.git(["checkout", "-q", "-b", "feat"], in: repo)
        fx.commit(repo, file: "feat.txt")                        // feat has no upstream
        fx.git(["checkout", "-q", "main"], in: repo)
        FileManager.default.createFile(atPath: repo + "/stash.txt", contents: Data("x".utf8))
        fx.git(["stash", "-q", "-u"], in: repo)
        FileManager.default.createFile(atPath: repo + "/untracked.txt", contents: Data("x".utf8))
        FileManager.default.createFile(atPath: repo + "/.env", contents: Data("SECRET=1".utf8))
        fx.file("home/Developer/old/node_modules/x/i.js")
        try? "node_modules\n.env\n".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)

        let scan = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: false))
        let reasons = scan.verdict.reasons
        #expect(reasons.contains(.uncommittedChanges(1)))
        #expect(reasons.contains(.stashes(1)))
        #expect(reasons.contains(.unpushedCommits(branch: "main", ahead: 1)))
        #expect(reasons.contains(.branchNotPushed("feat")))
        #expect(scan.git?.ignoredPaths == [".env"])          // node_modules is generated, .env is not
        #expect(!runner.gitCalls.contains { $0.contains("ls-remote") })
    }

    @Test func verificationComparesWithGitHub() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let repo = oldPublishedRepo(fx, runner)
        fx.commit(repo, file: "ahead.txt", date: Date.daysAgo(200, from: now))
        fx.git(["branch", "feat"], in: repo)
        fx.git(["tag", "v9"], in: repo)
        fx.age(repo, to: Date.daysAgo(200, from: now))
        let scan = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: true))
        #expect(scan.github == .checked)
        #expect(scan.verdict.reasons.contains(.unpushedCommits(branch: "main", ahead: 1)))
        #expect(scan.verdict.reasons.contains(.branchNotPushed("feat")))   // holds main's unpushed commit
        #expect(scan.verdict.reasons.contains(.tagsNotOnGitHub(1)))
        #expect(!scan.isTrashCandidate)
    }

    @Test func branchWithoutUpstreamButOnGitHubPasses() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let repo = oldPublishedRepo(fx, runner)
        fx.git(["checkout", "-q", "-b", "side"], in: repo)
        fx.commit(repo, file: "side.txt", date: Date.daysAgo(200, from: now))
        fx.git(["push", "-q", runner.remotes["origin"]!, "side"], in: repo)   // pushed by URL: no upstream, no tracking ref
        fx.git(["checkout", "-q", "main"], in: repo)
        fx.age(repo, to: Date.daysAgo(200, from: now))
        let unverified = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: false))
        #expect(unverified.verdict.reasons == [.branchNotPushed("side")])
        let verified = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: true))
        #expect(verified.verdict == .safeToRemove, "\(verified.verdict)")
    }

    @Test func mergedBranchThatWasNeverPushedHoldsNothingNew() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let repo = oldPublishedRepo(fx, runner)
        fx.git(["branch", "claude/merged-work"], in: repo)   // same commit as main, which is on GitHub
        fx.age(repo, to: Date.daysAgo(200, from: now))
        let s = scanner(fx, runner)
        #expect(await s.scan(entry(fx, "old"), options: options(verify: false)).verdict == .safeToRemove)
        let verified = await s.scan(entry(fx, "old"), options: options(verify: true))
        #expect(verified.verdict == .safeToRemove, "\(verified.verdict)")
        #expect(verified.isTrashCandidate)
    }

    @Test func gitHubAheadCantBeProved() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        _ = oldPublishedRepo(fx, runner)
        // Someone else pushes to GitHub; this Mac never fetched it.
        let other = fx.path("other")
        fx.git(["clone", "-q", runner.remotes["origin"]!, other])
        fx.commit(other, file: "theirs.txt")
        fx.git(["push", "-q", "origin", "main"], in: other)
        let scan = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: true))
        #expect(scan.verdict.reasons == [.remoteAhead("main")])
    }

    @Test func remoteThatIsGoneFailsVerification() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        _ = oldPublishedRepo(fx, runner)
        runner.remotes["origin"] = fx.path("remotes/deleted.git")
        let scan = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: true))
        guard case .failed = scan.github else { Issue.record("expected a failed check, got \(scan.github)"); return }
        #expect(scan.verdict.reasons.contains { if case .verificationFailed = $0 { true } else { false } })
        #expect(!scan.isTrashCandidate)
    }

    @Test func remotesThatAreNotGitHub() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let lab = fx.repo("home/Developer/lab")
        fx.git(["remote", "add", "origin", "git@gitlab.com:me/lab.git"], in: lab)
        fx.repo("home/Developer/local")
        let s = scanner(fx, runner)
        #expect(await s.scan(entry(fx, "lab"), options: options(verify: true)).verdict.reasons == [.remoteNotGitHub("origin")])
        #expect(await s.scan(entry(fx, "local"), options: options(verify: true)).verdict.reasons == [.noRemote])
    }

    @Test func emptyRepositoryAndDetachedHead() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        fx.git(["init", "-q", "-b", "main"], in: fx.dir("home/Developer/empty"))
        let detached = oldPublishedRepo(fx, runner, name: "detached")
        fx.git(["checkout", "-q", "--detach"], in: detached)
        let s = scanner(fx, runner)
        let empty = await s.scan(entry(fx, "empty"), options: options(verify: false))
        #expect(empty.verdict.reasons.contains(.noCommits))
        let d = await s.scan(entry(fx, "detached"), options: options(verify: false))
        #expect(d.verdict.reasons.contains(.detachedHead))
    }

    @Test func linkedWorktreeIsNeverACandidate() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        let repo = oldPublishedRepo(fx, runner)
        fx.git(["worktree", "add", "-q", fx.developer + "/old-wt"], in: repo)
        let scan = await scanner(fx, runner).scan(entry(fx, "old-wt"), options: options(verify: true))
        #expect(scan.verdict == .linkedWorktree)
        #expect(scan.git?.isWorktree == true)
        #expect(!scan.isTrashCandidate)
    }

    @Test func foldersOutsideHomeAreRefused() async {
        let fx = Fixture()
        fx.file("external/proj/a.txt")
        let runner = FixtureRunner(fx)
        let e = ProjectEntry(root: fx.path("external"), path: fx.path("external/proj"), kind: .directory)
        let scan = await scanner(fx, runner).scan(e, options: options(verify: false))
        #expect(scan.removalRefusal == .outsideAllowedRoots)
    }

    // MARK: - Commands

    @Test func checksNeverWriteOrFetch() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        _ = oldPublishedRepo(fx, runner)
        _ = await scanner(fx, runner).scan(entry(fx, "old"), options: options(verify: true))
        #expect(!runner.gitCalls.isEmpty)
        for args in runner.gitCalls {
            #expect(args.first == "-C" || args.first == "--no-optional-locks", "\(args)")
            #expect(!args.contains { ["fetch", "pull", "push", "commit", "add", "gc"].contains($0) }, "\(args)")
        }
        #expect(runner.calls.allSatisfy { $0.0 == ProjectTools.git })
    }

    // MARK: - gh

    @Test func githubAvailability() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        #expect(await scanner(fx, runner, gh: "/opt/homebrew/bin/gh").githubAvailability(verify: false) == .off)
        #expect(runner.calls.isEmpty)
        #expect(await scanner(fx, runner, gh: nil).githubAvailability(verify: true) == .ghMissing)

        runner.gh = { args in
            #expect(args == ["api", "user", "--jq", ".login"])
            return CommandResult(exitCode: 0, stdout: "DarthQach\n", stderr: "")
        }
        #expect(await scanner(fx, runner, gh: "/opt/homebrew/bin/gh").githubAvailability(verify: true)
                == .available(login: "DarthQach", gh: "/opt/homebrew/bin/gh"))

        runner.gh = { _ in CommandResult(exitCode: 4, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login") }
        #expect(await scanner(fx, runner, gh: "/opt/homebrew/bin/gh").githubAvailability(verify: true) == .notSignedIn)

        runner.gh = { _ in CommandResult(exitCode: 1, stdout: "", stderr: "error connecting to api.github.com") }
        #expect(await scanner(fx, runner, gh: "/opt/homebrew/bin/gh").githubAvailability(verify: true) == .failed(.offline))
    }

    // MARK: - Stream

    @Test func streamListsChecksAndSorts() async {
        let fx = Fixture()
        let runner = FixtureRunner(fx)
        runner.gh = { _ in CommandResult(exitCode: 0, stdout: "demo\n", stderr: "") }
        _ = oldPublishedRepo(fx, runner)
        fx.file("home/Developer/fresh/a.txt", modified: Date())
        var listed: ProjectListing?, github: GitHubAvailability?, finished: [ProjectScan] = [], projects = 0
        for await event in scanner(fx, runner, gh: "/opt/homebrew/bin/gh").scan(roots: [fx.developer], options: options(verify: true)) {
            switch event {
            case .listed(let l): listed = l
            case .github(let g): github = g
            case .project: projects += 1
            case .finished(let all): finished = all
            }
        }
        #expect(listed?.entries.count == 2)
        #expect(projects == 2)
        #expect(github == .available(login: "demo", gh: "/opt/homebrew/bin/gh"))
        #expect(finished.map(\.name) == ["old", "fresh"])   // safe to remove before no git
    }
}
