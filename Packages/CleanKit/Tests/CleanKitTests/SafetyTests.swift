import Foundation
import SafetyKit
import Testing
@testable import CleanKit

@Suite("Safety: what can never enter a plan")
struct PlanSafetyTests {
    /// A rules file someone could submit by mistake or on purpose.
    static let malicious: [String] = [
        "~/Library/Mail/*", "~/Library/Mail/V10/*", "/System/*", "/usr/*", "/bin/*", "/private/var/db/*",
        "~/Library/Mobile Documents/*", "~/Library/Mobile Documents/*/*", "~/Library/Keychains/*", "~/Library/Safari/*",
        "~/Library/Caches", "~/Library", "~", "~/Library/Developer/Xcode", "~/Downloads", "~/.Trash",
        "/Library/Caches/*", "/Applications/*", "/Users/*", "/Volumes/*", "/*",
        "~/Library/Developer/Xcode/../../Mail/*", "~/Library/Caches/escape/*",
    ]

    @Test func protectedPathsNeverEnterAPlan() async throws {
        let f = try Fixture()
        try f.symlink("Library/Caches/escape", to: f.path("Library/Mail"))
        let rules = RuleSet(rules: Self.malicious.enumerated().map { rule("evil-\($0.offset)", [$0.element]) })
        let guardian = f.pathGuard()
        let plan = try await f.plan(rules: rules)
        let protected = PathGuard.protectedHomeSubtrees.map { f.home + "/" + $0 }
        for item in plan.allItems {
            #expect(guardian.verdict(for: item.path, context: .cleanup).allowed, "\(item.path)")
            #expect(PathGuard.isWithin(item.path, f.home), "\(item.path) is outside the home")
            for p in protected { #expect(!PathGuard.isWithin(item.path, p), "\(item.path) is protected") }
            for root in PathGuard.protectedRoots { #expect(!PathGuard.isWithin(item.path, root), "\(item.path)") }
            #expect(!PathGuard.homeContainerFolders.map { $0.isEmpty ? f.home : f.home + "/" + $0 }.contains(item.path))
        }
        #expect(!plan.allItems.contains { $0.path.contains("/Library/Mail") || $0.path.contains("escape") })
        #expect(plan.groups.reduce(0) { $0 + $1.refusedCount } > 0)
    }

    @Test func maliciousRulesExecutedStillTouchNothingProtected() async throws {
        let f = try Fixture()
        let rules = RuleSet(rules: Self.malicious.enumerated().map { rule("evil-\($0.offset)", [$0.element]) })
        let plan = try await f.plan(rules: rules)
        let exec = CleanupExecutor(remover: f.remover(), runner: f.runner(), log: InMemoryOperationLog())
        _ = await exec.execute(plan, selected: Set(plan.allItems.map(\.id)))
        #expect(f.exists("Library/Mail/V10/INBOX.mbox/1.emlx"))
        #expect(f.exists("Library/Mobile Documents/com~apple~CloudDocs/doc.txt"))
        #expect(f.exists("Library/Keychains/login.keychain-db"))
        #expect(f.exists("Library/Safari/History.db"))
    }

    @Test func forgedItemsAreRefusedAtExecution() async throws {
        // Even an item that never came from the planner (a forged plan) goes through SafeRemover's guard.
        let f = try Fixture()
        let mail = f.path("Library/Mail/V10")
        let r = rule("forged", ["~/x"])
        let forged = CleanupPlan(createdAt: Date(), groups: [CleanupGroup(
            id: "forged", rule: r,
            items: [CleanupItem(id: "forged:1", ruleID: "forged", path: mail, bytes: 1, modified: nil, isCommand: false),
                    CleanupItem(id: "forged:2", ruleID: "forged", path: "/System/Library", bytes: 1, modified: nil, isCommand: false)],
            bytes: 2, status: .ready, selectedByDefault: true)])
        let log = InMemoryOperationLog()
        let result = await CleanupExecutor(remover: f.remover(), runner: f.runner(), log: log).execute(forged, selected: ["forged:1", "forged:2"])
        #expect(result.outcomes.allSatisfy { $0.result == .refused })
        #expect(f.exists("Library/Mail/V10/INBOX.mbox/1.emlx"))
        #expect(await log.entries.map(\.result) == [.refused, .refused])
    }

    @Test func exclusionsAreCaseInsensitiveAndCoverContents() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/Keep/inner/a")
        try f.file("Library/Caches/Holder/secret/b")
        try f.file("Library/Caches/Other/c")
        let rules = RuleSet(rules: [rule("r", ["~/Library/Caches/*", "~/Library/Caches/Keep/*"],
                                         exclude: ["~/library/caches/KEEP", "~/Library/Caches/*/secret"])])
        let plan = try await f.plan(rules: rules)
        let paths = plan.paths("r")
        #expect(paths.contains(f.path("Library/Caches/Other")))
        #expect(!paths.contains { $0.contains("/Keep") }, "excluded folder and anything inside it")
        #expect(!paths.contains(f.path("Library/Caches/Holder")), "a folder that would contain an excluded match is dropped")
    }

    @Test func overlappingRulesNeverProduceOverlappingItems() async throws {
        let f = try Fixture()
        let rules = RuleSet(rules: [
            rule("outer", ["~/Library/Caches/Google"]),
            rule("inner", ["~/Library/Caches/Google/Chrome", "~/Library/Caches/Google/*"]),
            rule("dup", ["~/Library/Caches/Google"]),
        ])
        let plan = try await f.plan(rules: rules)
        #expect(plan.paths("outer") == [f.path("Library/Caches/Google")])
        #expect(plan.paths("inner").isEmpty && plan.paths("dup").isEmpty)
    }

    @Test func commandManagedFoldersAreNeverPathItems() async throws {
        let f = try Fixture()
        var rules = try RuleSet.bundled().rules
        rules.append(rule("greedy", ["~/Library/Caches/Homebrew", "~/Library/Caches/Homebrew/*", "~/Library/pnpm/store/*",
                                     "~/Library/Developer/CoreSimulator/Devices/*"]))
        let plan = try await f.plan(rules: RuleSet(rules: rules))
        #expect(plan.paths("greedy") == [f.path("Library/Developer/CoreSimulator/Devices/\(Fixture.availableUDID)")])
    }
}

@Suite("Directory sizer")
struct SizerTests {
    @Test func allocatedSizesHardLinksOnceNoSymlinks() async throws {
        let f = try Fixture(populate: false)
        let a = try f.file("tree/a.bin", bytes: 100_000)
        try f.file("tree/sub/deeper/b.bin", bytes: 50_000)
        try FileManager.default.linkItem(atPath: a, toPath: f.path("tree/sub/a-hardlink.bin"))
        try f.file("elsewhere/huge.bin", bytes: 1_000_000)
        try f.symlink("tree/link", to: f.path("elsewhere"))
        f.age("tree", days: 10)
        f.setDate(f.path("tree/sub/deeper/b.bin"), f.now.addingTimeInterval(-3600))

        let info = await DirectorySizer.size(f.path("tree"))
        var sa = stat(), sb = stat()
        lstat(a, &sa); lstat(f.path("tree/sub/deeper/b.bin"), &sb)
        let expected = Int64(sa.st_blocks + sb.st_blocks) * 512
        #expect(info.bytes >= expected && info.bytes < expected + 64 * 1024, "hard link counted once, symlink target not counted")
        #expect(info.fileCount == 3)   // a.bin, b.bin, link (the hard link is the same file)
        #expect(info.isDirectory && info.exists && info.unreadable == 0)
        let newest = try #require(info.newestModified)
        #expect(abs(newest.timeIntervalSince(f.now.addingTimeInterval(-3600))) < 2)
    }

    @Test func manyRootsInParallelMatchSequential() async throws {
        let f = try Fixture(populate: false)
        var roots: [String] = []
        for i in 0..<12 {
            for j in 0..<30 { try f.file("r\(i)/d\(j % 5)/f\(j)", bytes: 1000 * (j + 1)) }
            roots.append(f.path("r\(i)"))
        }
        let parallel = await DirectorySizer.size(roots, threads: 8)
        let sequential = DirectorySizer.sizeBlocking(roots, threads: 1)
        #expect(parallel == sequential)
        #expect(parallel.values.allSatisfy { $0.fileCount == 30 })
    }

    @Test func missingAndUnreadable() async throws {
        let f = try Fixture(populate: false)
        try f.file("locked/inner/x")
        chmod(f.path("locked/inner"), 0)
        defer { chmod(f.path("locked/inner"), 0o755) }
        let infos = await DirectorySizer.size([f.path("missing"), f.path("locked")])
        #expect(infos[f.path("missing")]?.exists == false)
        #expect(infos[f.path("locked")]?.unreadable == 1)
    }
}

@Suite("Parsers and helpers")
struct ParserTests {
    @Test func dockerSizes() {
        #expect(CommandMeasurer.parseDockerSize("1.5GB (60%)") == 1_500_000_000)
        #expect(CommandMeasurer.parseDockerSize("512kB") == 512_000)
        #expect(CommandMeasurer.parseDockerSize("0B") == 0)
        #expect(CommandMeasurer.parseDockerSize("12.3MB") == 12_300_000)
        #expect(CommandMeasurer.parseDockerSize("garbage") == nil)
    }

    @Test func simctlJSON() {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-16-0":[{"udid":"11111111-2222-3333-4444-555555555555","name":"iPhone 12","isAvailable":false},
        {"udid":"../../etc","name":"evil","isAvailable":false},{"udid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"ok","isAvailable":true}]}}
        """
        let found = CommandMeasurer.parseUnavailableDevices(json, devicesFolder: "/h/Devices")
        #expect(found == [.init(udid: "11111111-2222-3333-4444-555555555555", name: "iPhone 12", runtime: "iOS-16-0",
                                path: "/h/Devices/11111111-2222-3333-4444-555555555555")])
        #expect(CommandMeasurer.parseUnavailableDevices("not json", devicesFolder: "/x").isEmpty)
    }

    @Test func storePath() {
        #expect(CommandMeasurer.parseStorePath("/Users/me/Library/pnpm/store/v10\n") == "/Users/me/Library/pnpm/store/v10")
        #expect(CommandMeasurer.parseStorePath("relative/path") == nil)
    }

    @Test func languageCodes() {
        #expect(RuleEvaluator.languageCode("en_GB") == "en")
        #expect(RuleEvaluator.languageCode("es-419") == "es")
        #expect(RuleEvaluator.languageCode("English") == "en")
        #expect(RuleEvaluator.languageCode("zh-Hans") == "zh")
        #expect(RuleEvaluator.languageCode("Base") == "base")
    }

    @Test func commandLineQuoting() {
        #expect(CommandInvocation.commandLine("/usr/local/bin/docker", ["system", "df", "--format", "{{json .}}"])
                == "/usr/local/bin/docker system df --format '{{json .}}'")
    }

    @Test func exclusionOverlap() {
        let c = GlobExpander.components
        #expect(GlobExpander.overlapsExclusion(path: c("/h/Caches/CloudKit"), pattern: c("/h/caches/cloudkit")))
        #expect(GlobExpander.overlapsExclusion(path: c("/h/Caches/CloudKit/x"), pattern: c("/h/Caches/CloudKit")))
        #expect(GlobExpander.overlapsExclusion(path: c("/h/Caches"), pattern: c("/h/Caches/CloudKit")))
        #expect(!GlobExpander.overlapsExclusion(path: c("/h/Caches/Other"), pattern: c("/h/Caches/CloudKit")))
        #expect(GlobExpander.overlapsExclusion(path: c("/h/Caches/a.ShipIt"), pattern: c("/h/Caches/*.ShipIt")))
    }

    @Test func claimSet() {
        var claims = ClaimSet()
        claims.claim("/a/b/c")
        #expect(claims.conflicts("/a/b/c") && claims.conflicts("/a/b") && claims.conflicts("/a/b/c/d"))
        #expect(!claims.conflicts("/a/b/d") && !claims.conflicts("/a/bc"))
    }

    @Test func planTotals() {
        let r = rule("r", ["~/x"])
        let items = [CleanupItem(id: "r:1", ruleID: "r", path: "/1", bytes: 10, modified: nil, isCommand: false),
                     CleanupItem(id: "r:2", ruleID: "r", path: "/2", bytes: 5, modified: nil, isCommand: false)]
        let plan = CleanupPlan(createdAt: Date(), groups: [
            CleanupGroup(id: "r", rule: r, items: items, bytes: 15, status: .ready, selectedByDefault: true),
            CleanupGroup(id: "o", rule: rule("o", ["~/y"], optIn: true), items: [], bytes: 0, status: .ready, selectedByDefault: false),
        ])
        #expect(plan.bytes(selected: ["r:1"]) == 10)
        #expect(plan.bytes(selected: ["r:1", "r:2"], in: .userCaches) == 15)
        #expect(plan.defaultSelection() == ["r:1", "r:2"])
    }
}
