import Foundation
import SafetyKit

/// Folder names that hold generated or downloaded files. They count toward a project's size but never toward
/// its "last change": a fresh `npm install` doesn't make an old project active.
public enum ProjectSkipList {
    public static let directories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", "vendor", "dist", "target",
        ".venv", "venv", "__pycache__", ".next", ".gradle", ".swiftpm",
    ]
    /// Files the system writes on its own (Finder writes `.DS_Store` when a folder is merely opened).
    public static let files: Set<String> = [".DS_Store"]
    /// Folders the `.gitignore` a backup writes leaves out (see `BackupStep.gitignore`). A repository inside one of
    /// these can't become a bare pointer, so only these (and `.git`) are left out when looking for repositories.
    public static let ignoredByBackup: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", "dist", "target", ".venv", "venv", "__pycache__", ".next",
    ]
}

/// Size and dates of a project folder, from one walk.
public struct FolderMeasure: Sendable, Hashable {
    /// Allocated bytes of everything, skipped folders included (what the Trash would take). Hard links count once.
    public var bytes: Int64
    public var fileCount: Int
    /// Newest modification date of a file outside the skipped folders.
    public var newestModified: Date?
    /// The folder's own modification date, used to skip a removal when the folder changed after the check.
    public var ownModified: Date?
    /// Entries the walk couldn't read.
    public var unreadable: Int
    /// Folders inside this one that are git repositories themselves (they hold a `.git` folder or file), relative to
    /// this folder, outermost only, outside `ProjectSkipList.ignoredByBackup` folders. The folder itself isn't listed.
    public var nestedRepositories: [String]

    public init(bytes: Int64, fileCount: Int, newestModified: Date?, ownModified: Date?, unreadable: Int, nestedRepositories: [String] = []) {
        self.bytes = bytes; self.fileCount = fileCount; self.newestModified = newestModified
        self.ownModified = ownModified; self.unreadable = unreadable; self.nestedRepositories = nestedRepositories
    }
}

/// A git remote (fetch URL).
public struct RemoteInfo: Sendable, Hashable {
    public let name: String
    public let url: String
    /// "owner/name" when the remote is on github.com.
    public let ownerRepo: String?

    public init(name: String, url: String, ownerRepo: String?) {
        self.name = name; self.url = url; self.ownerRepo = ownerRepo
    }

    public var isGitHub: Bool { ownerRepo != nil }
    public var webURL: URL? { ownerRepo.flatMap { URL(string: "https://github.com/\($0)") } }
}

public struct BranchInfo: Sendable, Hashable {
    public let name: String
    public let sha: String
    /// "origin/main"; nil when the branch tracks nothing.
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// The upstream branch was deleted on the remote.
    public let upstreamGone: Bool

    public init(name: String, sha: String, upstream: String?, ahead: Int = 0, behind: Int = 0, upstreamGone: Bool = false) {
        self.name = name; self.sha = sha; self.upstream = upstream; self.ahead = ahead; self.behind = behind
        self.upstreamGone = upstreamGone
    }
}

public struct TagInfo: Sendable, Hashable {
    public let name: String
    /// The tag object for annotated tags, the commit for lightweight ones (what `ls-remote` lists unpeeled).
    public let sha: String

    public init(name: String, sha: String) { self.name = name; self.sha = sha }
}

/// What git says about a project, read without changing anything.
public struct GitState: Sendable, Hashable {
    /// `.git` is a file: a linked worktree (or a nested checkout) whose history lives elsewhere.
    public var isWorktree: Bool
    /// nil when HEAD is detached or the repository has no commits yet.
    public var headBranch: String?
    public var headSHA: String?
    public var hasCommits: Bool
    /// Changed, conflicted and untracked entries.
    public var uncommittedCount: Int
    public var stashCount: Int
    public var branches: [BranchInfo]
    public var tags: [TagInfo]
    public var remotes: [RemoteInfo]
    /// Newest commit on any branch or tag, stashes excluded.
    public var lastCommitDate: Date?
    /// Ignored files and folders outside the generated folders (`.env`, local databases…). They are not in git
    /// and would go to the Trash with the project.
    public var ignoredPaths: [String]
    public var ignoredCount: Int
    /// Untracked folders inside the work tree that are git repositories themselves. `git add -A` would record each
    /// one as a bare pointer to a commit, without its files.
    public var embeddedRepositories: [String]

    public init(isWorktree: Bool = false, headBranch: String?, headSHA: String?, hasCommits: Bool, uncommittedCount: Int = 0,
                stashCount: Int = 0, branches: [BranchInfo] = [], tags: [TagInfo] = [], remotes: [RemoteInfo] = [],
                lastCommitDate: Date?, ignoredPaths: [String] = [], ignoredCount: Int = 0, embeddedRepositories: [String] = []) {
        self.isWorktree = isWorktree; self.headBranch = headBranch; self.headSHA = headSHA; self.hasCommits = hasCommits
        self.uncommittedCount = uncommittedCount; self.stashCount = stashCount; self.branches = branches; self.tags = tags
        self.remotes = remotes; self.lastCommitDate = lastCommitDate; self.ignoredPaths = ignoredPaths
        self.ignoredCount = ignoredCount; self.embeddedRepositories = embeddedRepositories
    }

    /// `origin` when it is on GitHub, else the first GitHub remote.
    public var githubRemote: RemoteInfo? {
        remotes.first { $0.name == "origin" && $0.isGitHub } ?? remotes.first { $0.isGitHub }
    }

    public var isDetached: Bool { headBranch == nil && hasCommits }
}

/// Whether KeelMac can talk to GitHub through the user's own `gh` login.
public enum GitHubAvailability: Sendable, Hashable {
    case available(login: String, gh: String)
    /// Verify with GitHub is off; nothing was asked.
    case off
    case ghMissing
    case notSignedIn
    case failed(CommandFailure)

    public var login: String? { if case .available(let login, _) = self { login } else { nil } }
}

/// The result of comparing the project with its GitHub remote (`git ls-remote`).
public enum GitHubCheck: Sendable, Hashable {
    /// Verify with GitHub is off: only local tracking information was used.
    case off
    /// `git ls-remote` answered; the reasons say whether anything is missing on GitHub.
    case checked
    case failed(CommandFailure)
    /// Not a git repository, or no GitHub remote.
    case notApplicable
}

/// Why a command failed, mapped from git and gh output. `message` keeps the tool's own last line.
public enum CommandFailure: Error, Sendable, Hashable {
    case authentication
    case repositoryNotFound
    case repositoryExists(String)
    case offline
    case rejected
    case identityMissing
    case toolMissing
    case timedOut
    case other(exit: Int32, message: String)

    public static func classify(_ result: CommandResult) -> CommandFailure {
        if result.timedOut { return .timedOut }
        if result.exitCode == 127 { return .toolMissing }
        let text = result.stderr + "\n" + result.stdout
        let lower = text.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { lower.contains($0.lowercased()) } }
        if has(["Authentication failed", "could not read Username", "could not read Password", "Permission denied (publickey",
                "terminal prompts disabled", "Invalid username or token", "HTTP 401", "gh auth login"]) { return .authentication }
        if has(["Repository not found", "does not appear to be a git repository", "Could not resolve to a Repository"]) {
            return .repositoryNotFound
        }
        if has(["Could not resolve host", "unable to access", "Network is unreachable", "Operation timed out",
                "Connection refused", "Failed to connect", "error connecting to api.github.com"]) { return .offline }
        if has(["[rejected]", "non-fast-forward", "pre-receive hook declined", "failed to push some refs", "GH001"]) {
            return .rejected
        }
        if has(["Please tell me who you are", "unable to auto-detect email address", "empty ident name"]) { return .identityMissing }
        return .other(exit: result.exitCode, message: toolLine(result))
    }

    /// The last line the tool wrote to stderr, else to stdout.
    static func toolLine(_ result: CommandResult?) -> String {
        guard let result else { return "" }
        let fromErr = lastLine(result.stderr)
        return fromErr.isEmpty ? lastLine(result.stdout) : fromErr
    }

    static func lastLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return String(line.prefix(300))
    }
}

/// One thing that stands between a project and a complete copy on GitHub.
public enum ProjectReason: Sendable, Hashable {
    case uncommittedChanges(Int)
    case stashes(Int)
    case noCommits
    case detachedHead
    case noRemote
    /// Remotes exist but none is on GitHub. Carries the first remote's name.
    case remoteNotGitHub(String)
    /// The branch has commits GitHub doesn't have. `ahead` is nil when only verification found it.
    case unpushedCommits(branch: String, ahead: Int?)
    /// The branch isn't on GitHub at all.
    case branchNotPushed(String)
    /// GitHub has commits on this branch that this Mac hasn't fetched, so the local ones can't be proved to be there.
    case remoteAhead(String)
    case tagsNotOnGitHub(Int)
    case verificationFailed(CommandFailure)
}

public enum ProjectVerdict: Sendable, Hashable {
    /// On GitHub and untouched for longer than the limit.
    case safeToRemove
    /// On GitHub and still active.
    case keep
    case notBackedUp([ProjectReason])
    case noGit
    case linkedWorktree
    case symlink
    case unreadable(String?)

    /// Sort order: what needs a decision first.
    public var rank: Int {
        switch self {
        case .safeToRemove: 0
        case .notBackedUp: 1
        case .noGit: 2
        case .keep: 3
        case .linkedWorktree, .symlink: 4
        case .unreadable: 5
        }
    }

    public var reasons: [ProjectReason] { if case .notBackedUp(let r) = self { r } else { [] } }
}

/// One project folder after a check.
public struct ProjectScan: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let root: String
    public var git: GitState?
    public var github: GitHubCheck
    public var measure: FolderMeasure?
    /// The later of the last commit and the newest file change.
    public var lastChange: Date?
    public var isStale: Bool
    public var verdict: ProjectVerdict
    /// Why SafetyKit would refuse to move this folder (checked with `PathContext.userFile`).
    public var removalRefusal: RefusalReason?
    public var scannedAt: Date

    public init(path: String, name: String, root: String, git: GitState?, github: GitHubCheck, measure: FolderMeasure?,
                lastChange: Date?, isStale: Bool, verdict: ProjectVerdict, removalRefusal: RefusalReason?, scannedAt: Date) {
        self.path = path; self.name = name; self.root = root; self.git = git; self.github = github; self.measure = measure
        self.lastChange = lastChange; self.isStale = isStale; self.verdict = verdict; self.removalRefusal = removalRefusal
        self.scannedAt = scannedAt
    }

    /// Safe to remove, proved against GitHub, and allowed by SafetyKit.
    public var isTrashCandidate: Bool { verdict == .safeToRemove && github == .checked && removalRefusal == nil }

    /// Safe by local tracking information only: turn on Verify with GitHub to prove it.
    public var needsVerification: Bool { verdict == .safeToRemove && github != .checked }

    public var githubURL: URL? { git?.githubRemote?.webURL }

    /// The folder's path under its root, such as `cashflowpro/cashflowpro` for a repository inside a plain folder.
    public var relativePath: String {
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) && path.count > base.count ? String(path.dropFirst(base.count)) : name
    }

    /// A repository found inside a plain folder rather than directly under a root.
    public var isNested: Bool { relativePath.contains("/") }

    /// Git repositories inside this folder that a backup would record as bare pointers, without their files: every
    /// repository inside a plain folder, or the untracked ones inside a repository.
    public var embeddedRepositories: [String] {
        if let git { return git.embeddedRepositories }
        return measure?.nestedRepositories ?? []
    }

    /// A plain folder that only holds other repositories (they are listed on their own).
    public var holdsRepositories: Bool { git == nil && !embeddedRepositories.isEmpty }

    /// Whether Back up has something to offer. Never for a folder holding repositories git would save as pointers.
    public var canBackUp: Bool {
        guard embeddedRepositories.isEmpty else { return false }
        switch verdict {
        case .noGit, .notBackedUp: return true
        default: return false
        }
    }
}

public struct ProjectScanOptions: Sendable, Equatable {
    public var staleAfterDays: Int
    public var verifyWithGitHub: Bool
    public var skipDirectories: Set<String>
    public var now: Date
    public var concurrency: Int

    public init(staleAfterDays: Int = 180, verifyWithGitHub: Bool = false, skipDirectories: Set<String> = ProjectSkipList.directories,
                now: Date = Date(), concurrency: Int = 4) {
        self.staleAfterDays = staleAfterDays; self.verifyWithGitHub = verifyWithGitHub; self.skipDirectories = skipDirectories
        self.now = now; self.concurrency = max(1, concurrency)
    }
}

/// A direct subfolder of a projects root, or a repository inside one that isn't a repository itself.
public struct ProjectEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case directory, symlink, unreadable }
    public let root: String
    public let path: String
    public let kind: Kind

    public init(root: String, path: String, kind: Kind) { self.root = root; self.path = path; self.kind = kind }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct ProjectListing: Sendable, Hashable {
    public let entries: [ProjectEntry]
    /// Roots that don't exist or can't be read.
    public let unreadableRoots: [String]

    public init(entries: [ProjectEntry], unreadableRoots: [String]) { self.entries = entries; self.unreadableRoots = unreadableRoots }
}

public enum ProjectScanEvent: Sendable {
    case listed(ProjectListing)
    case github(GitHubAvailability)
    case project(ProjectScan)
    case finished([ProjectScan])
}
