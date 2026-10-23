import Foundation

/// The rules that turn git facts into a verdict. Pure functions.
public enum ProjectClassifier {
    /// Stale when both the last commit and the newest file change are older than the limit. A missing date counts
    /// as old (a folder without git has only file dates).
    public static func isStale(lastCommit: Date?, newestModified: Date?, limitDays: Int, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(max(0, limitDays)) * 86_400)
        func old(_ date: Date?) -> Bool { date.map { $0 < cutoff } ?? true }
        return old(lastCommit) && old(newestModified)
    }

    /// Reasons that don't depend on GitHub: work that exists only in this folder.
    public static func localReasons(_ git: GitState) -> [ProjectReason] {
        var reasons: [ProjectReason] = []
        if git.uncommittedCount > 0 { reasons.append(.uncommittedChanges(git.uncommittedCount)) }
        if git.stashCount > 0 { reasons.append(.stashes(git.stashCount)) }
        if !git.hasCommits { reasons.append(.noCommits) }
        if git.isDetached { reasons.append(.detachedHead) }
        if git.remotes.isEmpty {
            reasons.append(.noRemote)
        } else if git.githubRemote == nil {
            reasons.append(.remoteNotGitHub(git.remotes[0].name))
        }
        return reasons
    }

    /// Branch reasons from the last fetch's tracking information (no network). `contained` names branches without
    /// an upstream whose commits are all on some remote-tracking branch already (merged work): they hold nothing new.
    public static func trackingReasons(_ git: GitState, contained: Set<String> = []) -> [ProjectReason] {
        guard git.githubRemote != nil else { return [] }
        var reasons: [ProjectReason] = []
        for branch in git.branches {
            if branch.upstream == nil || branch.upstreamGone {
                if !contained.contains(branch.name) { reasons.append(.branchNotPushed(branch.name)) }
            } else if branch.ahead > 0 {
                reasons.append(.unpushedCommits(branch: branch.name, ahead: branch.ahead))
            }
        }
        return reasons
    }

    /// The branch name a local branch has on `remote`: its upstream's name when it tracks that remote, else its own.
    public static func remoteBranchName(_ branch: BranchInfo, remote: String) -> String {
        if let upstream = branch.upstream, upstream.hasPrefix(remote + "/") { return String(upstream.dropFirst(remote.count + 1)) }
        return branch.name
    }

    /// Tags whose object isn't on GitHub under the same name.
    public static func missingTags(_ tags: [TagInfo], remoteTags: [String: String]) -> Int {
        tags.filter { remoteTags[$0.name] != $0.sha }.count
    }

    public static func verdict(git: GitState?, reasons: [ProjectReason], isStale: Bool) -> ProjectVerdict {
        guard let git else { return .noGit }
        if git.isWorktree { return .linkedWorktree }
        if !reasons.isEmpty { return .notBackedUp(reasons) }
        return isStale ? .safeToRemove : .keep
    }
}
