import Foundation
import ProjectsKit
import SafetyKit
import Testing
@testable import KeelMac

/// Unit tests run with visual fixtures on (XCTest sets XCTestConfigurationFilePath), so the model starts with the
/// fixture projects and never runs git, gh or a removal.
@Suite("Projects")
@MainActor
struct ProjectsTests {
    @Test func onlyVerifiedProjectsCanGoToTheTrash() {
        let model = ProjectsModel(log: InMemoryOperationLog())
        #expect(model.count(.safeToRemove) == 3)
        #expect(model.unverifiedCount == 1)
        #expect(model.trashCandidates.map(\.name) == ["weather-widget", "recipe-api"])
        model.selection = Set(model.scans.map(\.id))
        #expect(model.selectedTrashable.count == 2)
        #expect(model.selectedBytes == 1_840_000_000 + 412_000_000)
    }

    @Test func filtersSplitTheList() {
        let model = ProjectsModel(log: InMemoryOperationLog())
        #expect(model.count(.all) == model.scans.count)
        #expect(model.count(.notBackedUp) == 2)
        #expect(model.count(.noGit) == 2)
        #expect(model.count(.keep) == 1)
        model.filter = .noGit
        #expect(model.visible.allSatisfy { $0.verdict == .noGit })
    }

    @Test func trashInFixturesRemovesNothing() async {
        let model = ProjectsModel(log: InMemoryOperationLog())
        let before = model.scans.count
        let outcomes = await model.trash(model.trashCandidates)
        #expect(outcomes.isEmpty)
        #expect(model.scans.count == before)
    }

    @Test func screenContextNamesStatusesAndReasons() {
        let model = ProjectsModel(log: InMemoryOperationLog())
        let game = model.scans.first { $0.name == "game-prototype" }!
        let context = ScreenContext.projects(model, selected: [game])
        let text = context.rendered()
        #expect(text.contains("Projects"))
        #expect(text.contains("Safe to remove: 3"))
        #expect(text.contains("Uncommitted changes: 4"))
        #expect(text.contains("Branch physics isn’t on GitHub"))
        #expect(context.hasUserSelection)
        #expect(!context.suggestions.isEmpty)
    }

    @Test func listProjectsToolReadsTheLastCheckOnly() {
        let model = ProjectsModel(log: InMemoryOperationLog())
        let all = ListProjectsTool.render(model, filter: .all, limit: 40)
        #expect(all.contains("keelmac://open/projects"))
        #expect(all.contains("weather-widget"))
        #expect(all.contains("Safe, unverified"))
        let notBacked = ListProjectsTool.render(model, filter: .notBackedUp, limit: 1)
        #expect(notBacked.contains("game-prototype"))
        #expect(notBacked.contains("and 1 more"))
    }

    @Test func everyStatusAndReasonHasWords() {
        let verdicts: [ProjectVerdict] = [.safeToRemove, .keep, .notBackedUp([]), .noGit, .linkedWorktree, .symlink, .unreadable(nil), .unreadable("x")]
        for v in verdicts { #expect(!v.title.isEmpty); #expect(!v.explanation.isEmpty) }
        let reasons: [ProjectReason] = [.uncommittedChanges(1), .stashes(1), .noCommits, .detachedHead, .noRemote, .remoteNotGitHub("lab"),
                                        .unpushedCommits(branch: "main", ahead: 2), .unpushedCommits(branch: "main", ahead: nil),
                                        .branchNotPushed("feat"), .remoteAhead("main"), .tagsNotOnGitHub(1), .verificationFailed(.offline)]
        for r in reasons { #expect(!r.text.isEmpty) }
        let failures: [CommandFailure] = [.authentication, .repositoryNotFound, .repositoryExists("o/n"), .offline, .rejected,
                                          .identityMissing, .toolMissing, .timedOut, .other(exit: 3, message: ""), .other(exit: 3, message: "boom")]
        for f in failures { #expect(!f.text.isEmpty) }
        #expect(CommandFailure.other(exit: 3, message: "boom").text == "boom")
        for k in BackupStep.Kind.allCases { #expect(!k.title.isEmpty) }
        let availability: [GitHubAvailability] = [.available(login: "demo", gh: "/opt/homebrew/bin/gh"), .off, .ghMissing, .notSignedIn, .failed(.offline)]
        for a in availability { #expect(!a.title.isEmpty); #expect(!a.detail.isEmpty) }
    }

    @Test func fixtureBackupPlanShowsEveryStep() throws {
        let model = ProjectsModel(log: InMemoryOperationLog())
        let sketches = model.scans.first { $0.name == "sketches" }!
        let plan = try BackupPlanner.plan(for: sketches, github: VisualFixtures.projectsGitHub, commitMessage: "Backup from KeelMac",
                                          fileExists: { _ in false }).get()
        #expect(plan.repository == "demo/sketches")
        #expect(plan.steps.first?.kind == .gitInit)
        #expect(plan.steps.contains { $0.kind == .createRepo })
    }
}
