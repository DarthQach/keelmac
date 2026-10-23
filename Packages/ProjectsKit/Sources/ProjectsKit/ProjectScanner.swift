import Foundation
import SafetyKit

/// Checks project folders. Read-only: git runs with `--no-optional-locks` and `-C <folder>`, verification uses
/// `git ls-remote` (never `fetch`), and gh is asked only who is signed in.
public struct ProjectScanner: Sendable {
    let runner: CommandRunning
    let pathGuard: PathGuard
    let git: String
    let gh: String?
    let measure: @Sendable (String, Set<String>) -> FolderMeasure

    public init(runner: CommandRunning, pathGuard: PathGuard, git: String = ProjectTools.git, gh: String? = ProjectTools.gh(),
                measure: @escaping @Sendable (String, Set<String>) -> FolderMeasure = { FolderWalker.measure($0, skipping: $1) }) {
        self.runner = runner; self.pathGuard = pathGuard; self.git = git; self.gh = gh; self.measure = measure
    }

    // MARK: - Listing

    /// Direct subfolders of each root, hidden ones left out, sorted by name. Roots are resolved, so a root reached
    /// through a symlink lists its real children once.
    public func listProjects(in roots: [String]) -> ProjectListing {
        var entries: [ProjectEntry] = []
        var unreadable: [String] = []
        var seen = Set<String>()
        for raw in roots {
            let expanded = pathGuard.expandTilde(raw)
            let root = PathGuard.canonical(URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                unreadable.append(raw); continue
            }
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !name.hasPrefix(".") {
                let path = root + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                let kind: ProjectEntry.Kind
                switch info.st_mode & S_IFMT {
                case S_IFDIR: kind = access(path, R_OK | X_OK) == 0 ? .directory : .unreadable
                case S_IFLNK:
                    var target = stat()
                    guard stat(path, &target) == 0, (target.st_mode & S_IFMT) == S_IFDIR else { continue }
                    kind = .symlink
                default: continue
                }
                guard seen.insert(path).inserted, !roots.contains(where: { pathGuard.expandTilde($0) == path }) else { continue }
                entries.append(ProjectEntry(root: root, path: path, kind: kind))
            }
        }
        return ProjectListing(entries: entries, unreadableRoots: unreadable)
    }

    // MARK: - GitHub login

    /// Who is signed in to gh. Off when verification is off; nothing is run then.
    public func githubAvailability(verify: Bool) async -> GitHubAvailability {
        guard verify else { return .off }
        guard let gh else { return .ghMissing }
        let r = await runner.run(gh, ["api", "user", "--jq", ".login"], timeout: 15)
        if r.succeeded, let login = GitHubParsers.login(fromAPI: r.stdout) { return .available(login: login, gh: gh) }
        // gh exits 4 when it has no login.
        if r.exitCode == 4 { return .notSignedIn }
        let failure = CommandFailure.classify(r)
        return failure == .authentication ? .notSignedIn : .failed(failure)
    }

    // MARK: - Checking

    public func scan(roots: [String], options: ProjectScanOptions) -> AsyncStream<ProjectScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                let listing = listProjects(in: roots)
                continuation.yield(.listed(listing))
                async let availability = githubAvailability(verify: options.verifyWithGitHub)
                var results: [ProjectScan] = []
                await withTaskGroup(of: ProjectScan.self) { group in
                    var pending = listing.entries.makeIterator()
                    var running = 0
                    while running < options.concurrency, let next = pending.next() {
                        group.addTask { await scan(next, options: options) }
                        running += 1
                    }
                    while let done = await group.next() {
                        results.append(done)
                        continuation.yield(.project(done))
                        if !Task.isCancelled, let next = pending.next() { group.addTask { await scan(next, options: options) } }
                    }
                }
                continuation.yield(.github(await availability))
                continuation.yield(.finished(results.sorted(by: Self.order)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What needs a decision first, then oldest first.
    public static func order(_ a: ProjectScan, _ b: ProjectScan) -> Bool {
        if a.verdict.rank != b.verdict.rank { return a.verdict.rank < b.verdict.rank }
        switch (a.lastChange, b.lastChange) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return true
        case (_?, nil): return false
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Checks one folder.
    public func scan(_ entry: ProjectEntry, options: ProjectScanOptions) async -> ProjectScan {
        let refusal = pathGuard.verdict(for: entry.path, context: .userFile).reason
        func result(git: GitState? = nil, github: GitHubCheck = .notApplicable, measure: FolderMeasure? = nil,
                    verdict: ProjectVerdict, stale: Bool = false, lastChange: Date? = nil) -> ProjectScan {
            ProjectScan(path: entry.path, name: entry.name, root: entry.root, git: git, github: github, measure: measure,
                        lastChange: lastChange, isStale: stale, verdict: verdict, removalRefusal: refusal, scannedAt: options.now)
        }
        switch entry.kind {
        case .symlink: return result(verdict: .symlink)
        case .unreadable: return result(verdict: .unreadable(nil))
        case .directory: break
        }

        let folder = measure(entry.path, options.skipDirectories)
        var dotGit = stat()
        let hasDotGit = lstat(entry.path + "/.git", &dotGit) == 0
        let isWorktree = hasDotGit && (dotGit.st_mode & S_IFMT) == S_IFREG
        guard hasDotGit, isWorktree || (dotGit.st_mode & S_IFMT) == S_IFDIR else {
            let stale = ProjectClassifier.isStale(lastCommit: nil, newestModified: folder.newestModified,
                                                  limitDays: options.staleAfterDays, now: options.now)
            return result(measure: folder, verdict: .noGit, stale: stale, lastChange: folder.newestModified)
        }

        let state: GitState
        switch await readGit(entry.path, isWorktree: isWorktree, skip: options.skipDirectories) {
        case .success(let s): state = s
        case .failure(let failure):
            let message: String? = if case .other(_, let m) = failure { m } else { nil }
            return result(measure: folder, verdict: .unreadable(message), lastChange: folder.newestModified)
        }

        var reasons = ProjectClassifier.localReasons(state)
        var github: GitHubCheck = state.githubRemote == nil ? .notApplicable : .off
        if let remote = state.githubRemote, !isWorktree {
            if options.verifyWithGitHub {
                switch await verify(entry.path, state: state, remote: remote) {
                case .success(let verified):
                    github = .checked
                    reasons += verified
                case .failure(let failure):
                    github = .failed(failure)
                    reasons += ProjectClassifier.trackingReasons(state, contained: await containedInRemotes(entry.path, state: state))
                        + [.verificationFailed(failure)]
                }
            } else {
                reasons += ProjectClassifier.trackingReasons(state, contained: await containedInRemotes(entry.path, state: state))
            }
        }

        let stale = ProjectClassifier.isStale(lastCommit: state.lastCommitDate, newestModified: folder.newestModified,
                                              limitDays: options.staleAfterDays, now: options.now)
        let lastChange = [state.lastCommitDate, folder.newestModified].compactMap { $0 }.max()
        return result(git: state, github: github, measure: folder,
                      verdict: ProjectClassifier.verdict(git: state, reasons: reasons, isStale: stale),
                      stale: stale, lastChange: lastChange)
    }

    // MARK: - git

    func readGit(_ path: String, isWorktree: Bool, skip: Set<String>) async -> Result<GitState, CommandFailure> {
        let status = await runner.run(git, ["--no-optional-locks", "-C", path, "status", "--porcelain=v2", "--branch",
                                            "--show-stash", "--ignored"], timeout: 60)
        guard status.succeeded else { return .failure(CommandFailure.classify(status)) }
        let summary = GitParsers.status(status.stdout)

        async let refsRun = runner.run(git, ["--no-optional-locks", "-C", path, "for-each-ref",
                                             "--format=%(refname)%09%(objectname)%09%(upstream:short)%09%(upstream:track)",
                                             "refs/heads", "refs/tags"], timeout: 60)
        async let remotesRun = runner.run(git, ["-C", path, "remote", "-v"], timeout: 30)
        async let logRun = runner.run(git, ["--no-optional-locks", "-C", path, "log", "-1", "--format=%ct",
                                            "--exclude=refs/stash", "--all"], timeout: 60)
        let refs = GitParsers.refs(await refsRun.stdout)
        let remotes = GitParsers.remotes(await remotesRun.stdout)
        let lastCommit = GitParsers.commitDate(await logRun.stdout)

        let ignored = summary.ignored.filter { entry in
            let parts = entry.split(separator: "/").map(String.init)
            return !parts.contains(where: { skip.contains($0) }) && !ProjectSkipList.files.contains(parts.last ?? "")
        }
        return .success(GitState(isWorktree: isWorktree, headBranch: summary.headBranch, headSHA: summary.headSHA,
                                 hasCommits: summary.headSHA != nil || !refs.branches.isEmpty,
                                 uncommittedCount: summary.uncommittedCount, stashCount: summary.stashCount,
                                 branches: refs.branches, tags: refs.tags, remotes: remotes, lastCommitDate: lastCommit,
                                 ignoredPaths: Array(ignored.prefix(20)), ignoredCount: ignored.count))
    }

    /// Branches without an upstream (or with a deleted one) whose commits are all on remote-tracking branches from
    /// the last fetch, such as merged feature branches. Local only.
    func containedInRemotes(_ path: String, state: GitState) async -> Set<String> {
        var contained = Set<String>()
        for branch in state.branches where branch.upstream == nil || branch.upstreamGone {
            let r = await runner.run(git, ["--no-optional-locks", "-C", path, "rev-list", "--count", branch.sha, "--not", "--remotes"], timeout: 30)
            if r.succeeded, Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == 0 { contained.insert(branch.name) }
        }
        return contained
    }

    /// Compares every local branch and tag with what GitHub has. A branch is on GitHub when none of its commits is
    /// missing from GitHub's branches and tags (`rev-list --count <branch> --not <GitHub's commits>` is 0), whatever
    /// its name: a merged feature branch that was never pushed holds nothing new. Commits GitHub has but this Mac
    /// hasn't fetched can't be compared, so a branch whose GitHub copy is unknown here is reported as `remoteAhead`.
    func verify(_ path: String, state: GitState, remote: RemoteInfo) async -> Result<[ProjectReason], CommandFailure> {
        let listing = await runner.run(git, ["-C", path, "ls-remote", "--heads", "--tags", remote.name], timeout: 30)
        guard listing.succeeded else { return .failure(CommandFailure.classify(listing)) }
        let (heads, tags) = GitParsers.lsRemote(listing.stdout)
        let known = Array(Set(heads.values).union(tags.values)).sorted()
        var reasons: [ProjectReason] = []
        for branch in state.branches {
            let remoteSHA = heads[ProjectClassifier.remoteBranchName(branch, remote: remote.name)]
            if remoteSHA == branch.sha { continue }
            // --ignore-missing skips GitHub commits this Mac doesn't have.
            let count = await runner.run(git, ["--no-optional-locks", "-C", path, "rev-list", "--ignore-missing", "--count",
                                               branch.sha, "--not"] + known, timeout: 30)
            let missing = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if count.succeeded, missing == 0 { continue }
            if let remoteSHA, !(await hasObject(path, remoteSHA)) {
                reasons.append(.remoteAhead(branch.name))   // GitHub's commit isn't on this Mac
            } else if remoteSHA != nil {
                reasons.append(.unpushedCommits(branch: branch.name, ahead: count.succeeded ? missing : nil))
            } else {
                reasons.append(.branchNotPushed(branch.name))
            }
        }
        let missing = ProjectClassifier.missingTags(state.tags, remoteTags: tags)
        if missing > 0 { reasons.append(.tagsNotOnGitHub(missing)) }
        return .success(reasons)
    }

    func hasObject(_ path: String, _ sha: String) async -> Bool {
        await runner.run(git, ["--no-optional-locks", "-C", path, "cat-file", "-e", sha + "^{commit}"], timeout: 15).succeeded
    }
}
