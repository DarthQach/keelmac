import Foundation
import Testing
import SafetyKit
@testable import ProjectsKit

/// Folders that hold git repositories: a backup's `git add -A` would save each inner repository as a bare pointer to
/// a commit, without its files, so those folders are refused and the inner repositories are checked on their own.
@Suite("Nested repositories")
struct NestedRepositoryTests {
    let gh = "/opt/homebrew/bin/gh"

    func scanner(_ fx: Fixture) -> ProjectScanner { ProjectScanner(runner: FixtureRunner(fx), pathGuard: fx.pathGuard, gh: gh) }

    @Test func walkerFindsTheOutermostRepositories() {
        let fx = Fixture()
        let wrap = fx.dir("home/Developer/wrap")
        fx.repo("home/Developer/wrap/app")
        fx.repo("home/Developer/wrap/app/vendor/inner")          // inside app: belongs to app
        fx.repo("home/Developer/wrap/libs/core")
        fx.repo("home/Developer/wrap/node_modules/pkg")          // generated folder: skipped
        fx.file("home/Developer/wrap/checkout/.git", bytes: 30)  // a submodule checkout's .git file
        fx.file("home/Developer/wrap/notes.md", bytes: 10)
        let measure = FolderWalker.measure(wrap)
        #expect(measure.nestedRepositories == ["app", "checkout", "libs/core"])
        // A repository's own .git isn't nested in itself.
        #expect(FolderWalker.measure(wrap + "/app").nestedRepositories == ["vendor/inner"])
    }

    @Test func listingAddsRepositoriesInsidePlainFolders() {
        let fx = Fixture()
        fx.dir("home/Developer/plain/src")
        fx.file("home/Developer/plain/src/main.swift", bytes: 10)
        fx.repo("home/Developer/solo")
        fx.repo("home/Developer/solo/vendor/lib")                 // inside a repository: not listed
        fx.repo("home/Developer/wrap/app")
        fx.repo("home/Developer/wrap/a/b/c/deep")                 // four levels down: listed
        fx.repo("home/Developer/wrap/a/b/c/d/too-deep")           // five levels down: not listed
        fx.repo("home/Developer/wrap/node_modules/pkg")           // generated folder: not listed
        fx.repo("home/Developer/wrap/.hidden/repo")               // hidden folder: not listed
        let listing = scanner(fx).listProjects(in: [fx.developer])
        let relative = listing.entries.map { String($0.path.dropFirst(fx.developer.count + 1)) }
        #expect(relative == ["plain", "solo", "wrap", "wrap/a/b/c/deep", "wrap/app"])
        #expect(listing.entries.allSatisfy { $0.root == fx.developer && $0.kind == .directory })
    }

    @Test func aFolderOfRepositoriesIsListedAndRefused() async throws {
        let fx = Fixture()
        fx.repo("home/Developer/course/basics")
        fx.repo("home/Developer/course/flexbox")
        fx.file("home/Developer/course/README.md", bytes: 10)
        var scans: [ProjectScan] = []
        for await event in scanner(fx).scan(roots: [fx.developer], options: ProjectScanOptions()) {
            if case .finished(let all) = event { scans = all }
        }
        let course = try #require(scans.first { $0.relativePath == "course" })
        #expect(course.verdict == .noGit)
        #expect(course.embeddedRepositories == ["basics", "flexbox"])
        #expect(course.holdsRepositories && !course.canBackUp && !course.isNested)
        #expect(BackupPlanner.plan(for: course, github: .available(login: "demo", gh: gh), commitMessage: "m")
                == .failure(.containsRepositories(["basics", "flexbox"])))

        let basics = try #require(scans.first { $0.relativePath == "course/basics" })
        #expect(basics.name == "basics" && basics.isNested)
        #expect(basics.verdict == .notBackedUp([.noRemote]))
        #expect(basics.canBackUp && basics.embeddedRepositories.isEmpty)
        let plan = try BackupPlanner.plan(for: basics, github: .available(login: "demo", gh: gh), commitMessage: "m").get()
        #expect(plan.repository == "demo/basics")
    }

    @Test func untrackedRepositoryInsideARepositoryIsRefused() async throws {
        let fx = Fixture()
        let host = fx.repo("home/Developer/host")
        fx.repo("home/Developer/host/tools/clone")
        let scan = await scanner(fx).scan(ProjectEntry(root: fx.developer, path: host, kind: .directory), options: ProjectScanOptions())
        #expect(scan.git?.embeddedRepositories == ["tools/clone"])
        #expect(!scan.canBackUp && !scan.holdsRepositories)
        #expect(BackupPlanner.plan(for: scan, github: .available(login: "demo", gh: gh), commitMessage: "m")
                == .failure(.containsRepositories(["tools/clone"])))
    }

    @Test func ignoredOrTrackedRepositoriesInsideARepositoryAreFine() async throws {
        let fx = Fixture()
        // Ignored: a backup leaves it out.
        let ignoring = fx.repo("home/Developer/ignoring")
        try "vendor/\n".write(toFile: ignoring + "/.gitignore", atomically: true, encoding: .utf8)
        fx.git(["add", "-A"], in: ignoring); fx.git(["commit", "-q", "-m", "ignore vendor"], in: ignoring)
        fx.repo("home/Developer/ignoring/vendor/lib")
        // Tracked as a pointer already (a submodule-like gitlink): a backup doesn't change what it is.
        let linking = fx.repo("home/Developer/linking")
        fx.repo("home/Developer/linking/sub")
        fx.git(["add", "sub"], in: linking); fx.git(["commit", "-q", "-m", "add sub"], in: linking)
        for folder in [ignoring, linking] {
            let scan = await scanner(fx).scan(ProjectEntry(root: fx.developer, path: folder, kind: .directory), options: ProjectScanOptions())
            #expect(scan.measure?.nestedRepositories.count == 1)
            #expect(scan.embeddedRepositories.isEmpty, "\(folder)")
        }
    }

    /// The folders left out of the search are exactly the folders a backup's .gitignore leaves out.
    @Test func searchSkipsWhatABackupIgnores() {
        let ignoredFolders = Set(BackupStep.gitignore.split(separator: "\n").filter { $0.hasSuffix("/") }.map { String($0.dropLast()) })
        #expect(ignoredFolders.union([".git"]) == ProjectSkipList.ignoredByBackup)
    }

    @Test func statusKeepsUntrackedFolders() {
        let s = GitParsers.status("# branch.oid abc\n# branch.head main\n? tools/\n? notes.txt\n! build/\n")
        #expect(s.untrackedCount == 2)
        #expect(s.untrackedDirectories == ["tools/"])
    }
}
