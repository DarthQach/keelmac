import Foundation
import Testing
import SafetyKit
@testable import ProjectsKit

@Suite("Folder walker")
struct FolderWalkerTests {
    @Test func generatedFoldersCountForSizeNotForDates() {
        let fx = Fixture()
        let old = Date.daysAgo(300)
        fx.file("p/src/main.swift", bytes: 8192, modified: old)
        fx.file("p/node_modules/dep/index.js", bytes: 8192, modified: Date())
        fx.file("p/.build/debug/app", bytes: 8192, modified: Date())
        fx.file("p/.DS_Store", bytes: 10, modified: Date())
        let m = FolderWalker.measure(fx.path("p"))
        #expect(m.fileCount == 4)
        #expect(m.bytes >= 3 * 8192)
        #expect(abs((m.newestModified ?? .distantFuture).timeIntervalSince(old)) < 2)
        #expect(m.ownModified != nil)
        #expect(m.unreadable == 0)
    }

    @Test func nestedSkippedFolderEndsAtItsOwnLevel() {
        let fx = Fixture()
        let old = Date.daysAgo(400)
        fx.file("p/build/inner/x", modified: Date())
        fx.file("p/zz-after-build.txt", modified: old)
        let m = FolderWalker.measure(fx.path("p"))
        #expect(abs((m.newestModified ?? .distantFuture).timeIntervalSince(old)) < 2)
    }

    @Test func hardLinksOnceSymlinksNotFollowed() throws {
        let fx = Fixture()
        let big = fx.file("outside/big.bin", bytes: 4 * 1024 * 1024)
        fx.file("p/a.bin", bytes: 64 * 1024)
        try FileManager.default.linkItem(atPath: fx.path("p/a.bin"), toPath: fx.path("p/a-link.bin"))
        try FileManager.default.createSymbolicLink(atPath: fx.path("p/big-link"), withDestinationPath: big)
        let m = FolderWalker.measure(fx.path("p"))
        #expect(m.bytes < 1024 * 1024)
        #expect(m.fileCount == 2)   // a.bin once, the symlink itself
    }

    @Test func unreadableFolderIsCounted() throws {
        let fx = Fixture()
        fx.file("p/locked/secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.path("p/locked"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.path("p/locked")) }
        #expect(FolderWalker.measure(fx.path("p")).unreadable == 1)
    }
}

@Suite("Classifier")
struct ClassifierTests {
    let now = Date()

    @Test func staleNeedsBothDatesOld() {
        let old = Date.daysAgo(200, from: now), recent = Date.daysAgo(10, from: now)
        #expect(ProjectClassifier.isStale(lastCommit: old, newestModified: old, limitDays: 180, now: now))
        #expect(!ProjectClassifier.isStale(lastCommit: recent, newestModified: old, limitDays: 180, now: now))
        #expect(!ProjectClassifier.isStale(lastCommit: old, newestModified: recent, limitDays: 180, now: now))
        #expect(ProjectClassifier.isStale(lastCommit: nil, newestModified: old, limitDays: 180, now: now))
        #expect(ProjectClassifier.isStale(lastCommit: nil, newestModified: nil, limitDays: 180, now: now))
        #expect(!ProjectClassifier.isStale(lastCommit: old, newestModified: old, limitDays: 365, now: now))
    }

    func state(remotes: [RemoteInfo] = [RemoteInfo(name: "origin", url: "https://github.com/o/n.git", ownerRepo: "o/n")],
               branches: [BranchInfo] = [BranchInfo(name: "main", sha: "a", upstream: "origin/main")],
               uncommitted: Int = 0, stashes: Int = 0, head: String? = "main", hasCommits: Bool = true) -> GitState {
        GitState(headBranch: head, headSHA: hasCommits ? "a" : nil, hasCommits: hasCommits, uncommittedCount: uncommitted,
                 stashCount: stashes, branches: branches, remotes: remotes, lastCommitDate: nil)
    }

    @Test func cleanPushedHasNoReasons() {
        let s = state()
        #expect(ProjectClassifier.localReasons(s).isEmpty)
        #expect(ProjectClassifier.trackingReasons(s).isEmpty)
        #expect(ProjectClassifier.verdict(git: s, reasons: [], isStale: true) == .safeToRemove)
        #expect(ProjectClassifier.verdict(git: s, reasons: [], isStale: false) == .keep)
    }

    @Test func localReasons() {
        let s = state(remotes: [], uncommitted: 3, stashes: 1, head: nil)
        #expect(ProjectClassifier.localReasons(s) == [.uncommittedChanges(3), .stashes(1), .detachedHead, .noRemote])
        let lab = state(remotes: [RemoteInfo(name: "lab", url: "git@gitlab.com:o/n.git", ownerRepo: nil)])
        #expect(ProjectClassifier.localReasons(lab) == [.remoteNotGitHub("lab")])
        #expect(ProjectClassifier.trackingReasons(lab).isEmpty)
        #expect(ProjectClassifier.localReasons(state(branches: [], hasCommits: false)) == [.noCommits])
    }

    @Test func trackingReasons() {
        let s = state(branches: [
            BranchInfo(name: "main", sha: "a", upstream: "origin/main", ahead: 2),
            BranchInfo(name: "feat", sha: "b", upstream: nil),
            BranchInfo(name: "old", sha: "c", upstream: "origin/old", upstreamGone: true),
            BranchInfo(name: "behind", sha: "d", upstream: "origin/behind", behind: 5),
        ])
        #expect(ProjectClassifier.trackingReasons(s) == [.unpushedCommits(branch: "main", ahead: 2), .branchNotPushed("feat"), .branchNotPushed("old")])
        #expect(ProjectClassifier.trackingReasons(s, contained: ["feat"]) == [.unpushedCommits(branch: "main", ahead: 2), .branchNotPushed("old")])
    }

    @Test func remoteBranchNameFollowsUpstream() {
        #expect(ProjectClassifier.remoteBranchName(BranchInfo(name: "local", sha: "a", upstream: "origin/feature"), remote: "origin") == "feature")
        #expect(ProjectClassifier.remoteBranchName(BranchInfo(name: "local", sha: "a", upstream: "lab/feature"), remote: "origin") == "local")
        #expect(ProjectClassifier.missingTags([TagInfo(name: "v1", sha: "a"), TagInfo(name: "v2", sha: "b")], remoteTags: ["v1": "a", "v2": "x"]) == 1)
    }

    @Test func verdicts() {
        #expect(ProjectClassifier.verdict(git: nil, reasons: [], isStale: true) == .noGit)
        var wt = state(); wt.isWorktree = true
        #expect(ProjectClassifier.verdict(git: wt, reasons: [], isStale: true) == .linkedWorktree)
        #expect(ProjectClassifier.verdict(git: state(), reasons: [.stashes(1)], isStale: true) == .notBackedUp([.stashes(1)]))
    }

    @Test func trashCandidateNeedsProofAndPermission() {
        func scan(_ verdict: ProjectVerdict, _ github: GitHubCheck, refusal: RefusalReason? = nil) -> ProjectScan {
            ProjectScan(path: "/p", name: "p", root: "/", git: nil, github: github, measure: nil, lastChange: nil, isStale: true,
                        verdict: verdict, removalRefusal: refusal, scannedAt: Date())
        }
        #expect(scan(.safeToRemove, .checked).isTrashCandidate)
        #expect(!scan(.safeToRemove, .off).isTrashCandidate)
        #expect(scan(.safeToRemove, .off).needsVerification)
        #expect(!scan(.safeToRemove, .checked, refusal: .containerFolder).isTrashCandidate)
        #expect(!scan(.keep, .checked).isTrashCandidate)
        #expect(scan(.noGit, .notApplicable).canBackUp)
        #expect(!scan(.keep, .checked).canBackUp)
    }
}
