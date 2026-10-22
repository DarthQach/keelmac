import Foundation
import SafetyKit
import Testing
@testable import CleanKit

/// Live acceptance (opt-in, KEELMAC_LIVE_CLEAN=1): plans against the real home folder, then cleans ONLY a fixture
/// folder this test creates in DerivedData. Everything else in the plan stays untouched; the fixture goes to the real Trash.
@Suite("Live clean acceptance", .enabled(if: ProcessInfo.processInfo.environment["KEELMAC_LIVE_CLEAN"] == "1"))
struct LiveCleanAcceptanceTests {
    @Test func cleansOnlyTheSelectedFixture() async throws {
        let home = NSHomeDirectory()
        let name = "KeelMacAcceptance-\(UUID().uuidString.prefix(8))"
        let fixture = URL(fileURLWithPath: home + "/Library/Developer/Xcode/DerivedData/" + name)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Build/Products"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: fixture.appendingPathComponent("Build/Products/app.o"))

        let planner = CleanupPlanner(rules: try RuleSet.bundled(), pathGuard: PathGuard(), environment: CleanupEnvironment(hasFullDiskAccess: FullDiskAccess.isGranted()),
                                     runner: ProcessCommandRunner())
        let plan = await planner.plan()
        let item = try #require(plan.allItems.first { $0.path == fixture.path })
        let others = plan.allItems.filter { $0.id != item.id && !$0.isCommand }.prefix(20).map(\.path)

        let log = InMemoryOperationLog()
        let executor = CleanupExecutor(remover: SafeRemover(pathGuard: PathGuard(), mode: .trash, context: .cleanup), runner: ProcessCommandRunner(), log: log)
        let result = await executor.execute(plan, selected: [item.id])

        #expect(result.outcomes.map(\.result) == [.trashed])
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        for path in others { #expect(FileManager.default.fileExists(atPath: path), "untouched: \(path)") }
        let entries = await log.entries
        #expect(entries.count == 1)
        #expect(entries.first?.path == fixture.path)
        print("live clean: trashed \(fixture.path) (\(item.bytes) bytes); \(plan.allItems.count) items in the plan, \(others.count) checked untouched")
    }
}
