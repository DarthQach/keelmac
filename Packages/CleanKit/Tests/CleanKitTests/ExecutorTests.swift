import Foundation
import SafetyKit
import Testing
@testable import CleanKit

@Suite("Cleanup executor")
struct ExecutorTests {
    func executor(_ f: Fixture, runner: RecordingCommandRunner, whitelist: Whitelist = Whitelist(),
                  trasherCalls: CallLog? = nil) -> (CleanupExecutor, InMemoryOperationLog) {
        let log = InMemoryOperationLog()
        return (CleanupExecutor(remover: f.remover(whitelist: whitelist, trasherCalls: trasherCalls), runner: runner, log: log), log)
    }

    @Test func removesOnlySelectedItems() async throws {
        let f = try Fixture()
        let runner = f.runner()
        let plan = try await f.plan(runner: runner)
        let projA = try #require(plan.group(id: "xcode-derived-data")?.items.first { $0.path.hasSuffix("ProjA-abc") })
        let editor = try #require(plan.group(id: "user-caches")?.items.first { $0.path.hasSuffix("com.example.editor") })

        // After the preview: a new project build folder and a new file inside a planned cache folder.
        try f.file("Library/Developer/Xcode/DerivedData/ProjC-new/Build/c.o")
        try f.file("Library/Caches/com.example.editor/fresh-after-preview.db")

        let (exec, log) = executor(f, runner: runner)
        let result = await exec.execute(plan, selected: [projA.id, editor.id])

        #expect(!f.exists("Library/Developer/Xcode/DerivedData/ProjA-abc"))
        #expect(f.exists("Library/Developer/Xcode/DerivedData/ProjB-def"), "unselected item untouched")
        #expect(f.exists("Library/Developer/Xcode/DerivedData/ProjC-new/Build/c.o"), "item created after planning untouched")
        // The cache folder changed after the preview, so it is skipped and the new file survives.
        #expect(f.exists("Library/Caches/com.example.editor/fresh-after-preview.db"))
        let editorOutcome = try #require(result.outcomes.first { $0.path == editor.path })
        #expect(editorOutcome.result == .skipped && editorOutcome.refusal == .changedSincePreview)
        #expect(result.outcomes.first { $0.path == projA.path }?.result == .trashed)

        let entries = await log.entries
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .cleanup && $0.title == "Cleanup" && $0.batchID == result.batchID })
        #expect(result.bytesMovedToTrash == projA.bytes && result.bytesFreed == projA.bytes)
        #expect(runner.calls.filter { $0.1.contains("delete") || $0.1.contains("prune") || $0.1.contains("cleanup") }.isEmpty,
                "no command runs unless selected")
    }

    @Test func untouchedWhenNothingSelected() async throws {
        let f = try Fixture()
        let runner = f.runner()
        let plan = try await f.plan(runner: runner)
        let before = runner.calls.count
        let (exec, log) = executor(f, runner: runner)
        let result = await exec.execute(plan, selected: [])
        #expect(result.outcomes.isEmpty && result.commandResults.isEmpty && result.bytesFreed == 0)
        #expect(await log.entries.isEmpty)
        #expect(runner.calls.count == before)
        for item in plan.allItems where !item.isCommand {
            var st = stat()
            #expect(lstat(item.path, &st) == 0, "\(item.path)")
        }
    }

    @Test func unknownIDsAreIgnoredAndEntriesMatchSelection() async throws {
        let f = try Fixture()
        let runner = f.runner()
        let plan = try await f.plan(runner: runner)
        let real = plan.defaultSelection()
        let selection = real.union(["user-caches:/etc/hosts", "user-caches:" + f.path("Library/Mail"), "trash:/", "bogus"])
        let (exec, log) = executor(f, runner: runner)
        let result = await exec.execute(plan, selected: selection)
        let entries = await log.entries
        #expect(entries.count == real.count)
        #expect(result.outcomes.count + result.commandResults.count == real.count)
        #expect(Set(entries.map(\.path)).isSubset(of: Set(plan.allItems.map(\.path))))
        #expect(f.exists("Library/Mail/V10/INBOX.mbox/1.emlx"))
    }

    @Test func whitelistedItemIsSkipped() async throws {
        let f = try Fixture()
        let runner = f.runner()
        let plan = try await f.plan(runner: runner)
        let projA = try #require(plan.group(id: "xcode-derived-data")?.items.first { $0.path.hasSuffix("ProjA-abc") })
        let projB = try #require(plan.group(id: "xcode-derived-data")?.items.first { $0.path.hasSuffix("ProjB-def") })
        // The user whitelists ProjA after the preview.
        let (exec, log) = executor(f, runner: runner, whitelist: Whitelist(["~/Library/Developer/Xcode/DerivedData/ProjA-*"]))
        let result = await exec.execute(plan, selected: [projA.id, projB.id])
        #expect(f.exists("Library/Developer/Xcode/DerivedData/ProjA-abc"))
        #expect(!f.exists("Library/Developer/Xcode/DerivedData/ProjB-def"))
        let a = try #require(result.outcomes.first { $0.path == projA.path })
        #expect(a.result == .skipped && a.refusal == .whitelisted)
        #expect(await log.entries.first { $0.path == projA.path }?.result == .skipped)
    }

    @Test func whitelistedItemIsNeverPlanned() async throws {
        let f = try Fixture()
        let (planner, _) = try f.planner(whitelist: Whitelist(["~/Library/Caches/com.example.editor"]))
        let plan = await planner.plan()
        #expect(!plan.paths("user-caches").contains(f.path("Library/Caches/com.example.editor")))
        #expect(plan.group(id: "user-caches")?.refusedCount == 1)
    }

    @Test func commandItemsRunExactlyTheRuleCommand() async throws {
        let f = try Fixture()
        let runner = f.runner()
        let plan = try await f.plan(runner: runner)
        let ids = ["simulators-unavailable", "homebrew-cleanup", "pnpm-store", "docker-prune"].map { CleanupItem.commandID(rule: $0) }
        for id in ids { #expect(plan.item(id: id) != nil, "\(id)") }
        let before = runner.calls.count
        let (exec, log) = executor(f, runner: runner)
        let result = await exec.execute(plan, selected: Set(ids))

        let runs = runner.calls.dropFirst(before).filter { ["delete", "prune", "cleanup"].contains(where: $0.1.contains) }
        #expect(runs.map(\.0) == ["/usr/bin/xcrun", "/opt/homebrew/bin/pnpm", "/opt/homebrew/bin/brew", "/usr/local/bin/docker"])
        #expect(runs.map(\.1) == [["simctl", "delete", "unavailable"], ["store", "prune"], ["cleanup", "--prune=all", "-s"], ["system", "prune", "-f"]])
        #expect(result.commandResults.count == 4 && result.outcomes.isEmpty)
        let entries = await log.entries
        #expect(entries.count == 4 && entries.allSatisfy { $0.result == .ran && $0.reason == nil })
        #expect(entries.first?.path == "/usr/bin/xcrun simctl delete unavailable")
        // The simulator measurement after the run sees no unavailable devices: everything measured was freed.
        let sims = try #require(plan.item(id: CleanupItem.commandID(rule: "simulators-unavailable")))
        #expect(result.bytesFreedByCommands >= sims.bytes)
        #expect(entries.first?.bytes == sims.bytes)
    }

    @Test func failedCommandIsLogged() async throws {
        let f = try Fixture()
        f.state.failCommands = ["/opt/homebrew/bin/brew cleanup --prune=all -s"]
        let runner = f.runner()
        let plan = try await f.plan(runner: runner)
        let id = CleanupItem.commandID(rule: "homebrew-cleanup")
        let (exec, log) = executor(f, runner: runner)
        let result = await exec.execute(plan, selected: [id])
        #expect(result.commandResults[id]?.exitCode == 1)
        let entry = try #require(await log.entries.first)
        #expect(entry.result == .failed)
        #expect(entry.reason == "Exit code 1: Error: something went wrong")
        #expect(result.bytesFreed == 0)
    }

    @Test func trashIsEmptiedPermanently() async throws {
        let f = try Fixture()
        let runner = f.runner()
        let plan = try await f.plan(runner: runner)
        let trashItems = try #require(plan.group(id: "trash")?.items)
        let projA = try #require(plan.group(id: "xcode-derived-data")?.items.first)
        let calls = CallLog()
        let (exec, log) = executor(f, runner: runner, trasherCalls: calls)
        let result = await exec.execute(plan, selected: Set(trashItems.map(\.id) + [projA.id]))

        for item in trashItems {
            #expect(result.outcomes.first { $0.path == item.path }?.result == .deleted)
            var st = stat()
            #expect(lstat(item.path, &st) != 0)
        }
        #expect(calls.items == [projA.path], "only the non-Trash item goes through the trasher")
        #expect(result.outcomes.first { $0.path == projA.path }?.result == .trashed)
        #expect(result.bytesDeleted == trashItems.reduce(0) { $0 + $1.bytes })
        #expect(await log.entries.count == trashItems.count + 1)
        #expect(f.exists("Volumes/Ext/.Trashes/502/other-user.txt"))
    }

    @Test func defaultSelectionCleanupLogsEveryItem() async throws {
        let f = try Fixture()
        let runner = f.runner()
        let plan = try await f.plan(runner: runner)
        let selection = plan.defaultSelection()
        let (exec, log) = executor(f, runner: runner)
        let result = await exec.execute(plan, selected: selection)
        let entries = await log.entries
        #expect(entries.count == selection.count)
        #expect(entries.allSatisfy { [.trashed, .deleted, .ran, .skipped].contains($0.result) })
        // Never selected by default, never touched.
        #expect(f.exists("Library/Developer/Xcode/Archives/2020-01-01/Old.xcarchive"))
        #expect(f.exists("Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E"))
        #expect(f.exists("Library/Caches/CloudKit/state.db"))
        #expect(f.exists("Library/Mail/V10/INBOX.mbox/1.emlx"))
        #expect(f.exists(".npm/_logs/debug.log"))
        #expect(FileManager.default.fileExists(atPath: f.root + "/outside/big.bin"))
        #expect(result.bytesFreed > 0)
    }
}
