import Foundation
import ProjectsKit
import SwiftUI

// ProjectsKit returns values; these turn them into the user's language.

extension ProjectVerdict {
    var title: String {
        switch self {
        case .safeToRemove: String(localized: "Safe to remove")
        case .keep: String(localized: "Keep")
        case .notBackedUp: String(localized: "Not backed up")
        case .noGit: String(localized: "No git")
        case .linkedWorktree: String(localized: "Worktree")
        case .symlink: String(localized: "Link")
        case .unreadable: String(localized: "Couldn’t read")
        }
    }

    var tone: StatusBadge.Tone {
        switch self {
        case .safeToRemove: .success
        case .notBackedUp, .noGit: .warning
        case .unreadable: .danger
        case .keep, .linkedWorktree, .symlink: .neutral
        }
    }

    /// One sentence for the inspector when there are no reasons to list.
    var explanation: String {
        switch self {
        case .safeToRemove: String(localized: "Everything is on GitHub and nothing changed for longer than your limit.")
        case .keep: String(localized: "Everything is on GitHub, and you changed it recently.")
        case .notBackedUp: String(localized: "Some work exists only on this Mac.")
        case .noGit: String(localized: "This folder isn’t a git repository, so nothing of it is on GitHub.")
        case .linkedWorktree: String(localized: "A git worktree: its history lives in the main repository. Check that one instead.")
        case .symlink: String(localized: "A link to a folder elsewhere. Projects never moves links to the Trash.")
        case .unreadable(let message): message.map { String(localized: "Couldn’t read this folder: \($0)") } ?? String(localized: "Couldn’t read this folder.")
        }
    }
}

extension ProjectScan {
    /// The status word, marking a safe-looking project that hasn't been proved against GitHub.
    var statusTitle: String { needsVerification ? String(localized: "Safe, unverified") : verdict.title }
    var statusTone: StatusBadge.Tone { needsVerification ? .neutral : verdict.tone }
    var reasonSummary: String { verdict.reasons.map(\.text).joined(separator: "\n") }

    /// What the GitHub column shows.
    var githubText: String {
        if let repo = git?.githubRemote?.ownerRepo { return repo }
        switch verdict {
        case .noGit: return String(localized: "Not a repository")
        default: return git?.remotes.isEmpty == false ? String(localized: "Other remote") : String(localized: "No remote")
        }
    }
}

extension ProjectReason {
    var text: String {
        switch self {
        case .uncommittedChanges(let n): String(localized: "Uncommitted changes: \(n)")
        case .stashes(let n): String(localized: "Stashes: \(n). Stashes are never pushed.")
        case .noCommits: String(localized: "No commits yet")
        case .detachedHead: String(localized: "Detached HEAD: the checked-out commit isn’t on a branch")
        case .noRemote: String(localized: "No remote: nothing has been pushed anywhere")
        case .remoteNotGitHub(let name): String(localized: "Remote \(name) isn’t on GitHub")
        case .unpushedCommits(let branch, let ahead?): String(localized: "Commits on \(branch) not on GitHub: \(ahead)")
        case .unpushedCommits(let branch, nil): String(localized: "\(branch) has commits that aren’t on GitHub")
        case .branchNotPushed(let branch): String(localized: "Branch \(branch) isn’t on GitHub")
        case .remoteAhead(let branch): String(localized: "GitHub has newer commits on \(branch). Pull them, then check again.")
        case .tagsNotOnGitHub(let n): String(localized: "Tags not on GitHub: \(n)")
        case .verificationFailed(let failure): String(localized: "Couldn’t check GitHub: \(failure.text)")
        }
    }
}

extension CommandFailure {
    var text: String {
        switch self {
        case .authentication: String(localized: "git couldn’t sign in to GitHub. Run gh auth setup-git so git uses your gh login, then try again.")
        case .repositoryNotFound: String(localized: "GitHub doesn’t have this repository, or this account can’t see it.")
        case .repositoryExists(let name): String(localized: "\(name) already exists on GitHub. Choose another name.")
        case .offline: String(localized: "GitHub couldn’t be reached. Check the connection.")
        case .rejected: String(localized: "GitHub rejected the push. Pull first, or look for files over 100 MB.")
        case .identityMissing: String(localized: "git doesn’t know your name and email yet. Set them with git config --global user.name and user.email.")
        case .toolMissing: String(localized: "The command-line tool isn’t installed.")
        case .timedOut: String(localized: "It took too long and was stopped.")
        case .other(let exit, let message): message.isEmpty ? String(localized: "Exit code \(Int(exit))") : message
        }
    }
}

extension GitHubAvailability {
    var title: String {
        switch self {
        case .available(let login, _): String(localized: "Verified with GitHub as \(login)")
        case .off: String(localized: "GitHub verification is off")
        case .ghMissing: String(localized: "gh isn’t installed")
        case .notSignedIn: String(localized: "gh isn’t signed in")
        case .failed: String(localized: "Couldn’t reach GitHub")
        }
    }

    var detail: String {
        switch self {
        case .available: String(localized: "Every branch and tag was compared with GitHub just now.")
        case .off: String(localized: "Only this Mac’s last fetch is used. Turn on Verify with GitHub to prove a project is there before moving it to the Trash.")
        case .ghMissing: String(localized: "Branches are still compared with GitHub through git. Back up needs gh to create repositories: brew install gh.")
        case .notSignedIn: String(localized: "Branches are still compared through git. Sign in so Back up can create repositories:")
        case .failed(let failure): failure.text
        }
    }

    var tone: StatusBadge.Tone {
        switch self {
        case .available: .success
        case .off: .neutral
        case .ghMissing, .notSignedIn, .failed: .warning
        }
    }
}

extension BackupStep.Kind {
    var title: String {
        switch self {
        case .writeGitignore: String(localized: "Create a .gitignore for generated folders and .env")
        case .gitInit: String(localized: "Start a git repository")
        case .gitAdd: String(localized: "Stage every file")
        case .gitCommit: String(localized: "Commit")
        case .checkRepoName: String(localized: "Check that the name is free on GitHub")
        case .createRepo: String(localized: "Create the private repository")
        case .pushNewBranches: String(localized: "Push new branches")
        case .pushAll: String(localized: "Push all branches")
        case .pushTags: String(localized: "Push tags")
        }
    }
}

extension BackupPlanProblem {
    var text: String {
        switch self {
        case .githubUnavailable(let availability):
            String(localized: "Creating a repository needs gh, signed in to GitHub.") + " " + availability.title + "."
        case .detachedHead: String(localized: "HEAD is detached. Check out a branch first, so the backup includes your current commit.")
        case .linkedWorktree: String(localized: "This is a worktree. Back up its main repository instead.")
        case .nothingToBackUp: String(localized: "There is nothing a commit or a push can add. Anything left, like stashes, has to be handled in git.")
        case .notAFolder: String(localized: "Only real folders can be backed up.")
        case .invalidRepositoryName: String(localized: "Use only letters, numbers, dots, hyphens and underscores.")
        }
    }
}
