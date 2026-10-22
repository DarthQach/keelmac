import Foundation
import Testing
import SafetyKit
import HelperShared
@testable import MaintenanceKit

@Suite("MaintenanceCatalog")
struct MaintenanceCatalogTests {
    @Test func sevenTasksWithUniqueIDsInOrder() {
        #expect(MaintenanceCatalog.all.map(\.id) == MaintenanceTaskID.allCases)
        #expect(Set(MaintenanceCatalog.all.map(\.id)).count == 7)
    }

    @Test func commandLinesAreExactlyWhatRuns() {
        let expected: [MaintenanceTaskID: String] = [
            .flushDNS: "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder",
            .rebuildLaunchServices: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -gc -f -all local,system,user",
            .rebuildSpotlight: "/usr/bin/mdutil -E /",
            .verifyStartupDisk: "/usr/sbin/diskutil verifyVolume /",
            .clearFontCaches: "/usr/bin/atsutil databases -removeUser",
            .thinLocalSnapshots: "/usr/bin/tmutil thinlocalsnapshots / 20000000000 4",
            .runPeriodic: "/usr/sbin/periodic daily weekly monthly",
        ]
        for task in MaintenanceCatalog.all {
            #expect(task.commandLine == expected[task.id], "\(task.id)")
            #expect(task.commandLine == CommandLineFormatter.join(task.invocations), "\(task.id)")
        }
    }

    @Test func adminAndUserTasksAreExclusive() {
        let admin: Set<MaintenanceTaskID> = [.flushDNS, .rebuildSpotlight, .thinLocalSnapshots, .runPeriodic]
        for task in MaintenanceCatalog.all {
            #expect(task.needsAdmin == admin.contains(task.id), "\(task.id)")
            if task.needsAdmin {
                #expect(task.helperOperation != nil)
                #expect(task.userInvocations.isEmpty)
            } else {
                #expect(task.helperOperation == nil)
                #expect(!task.userInvocations.isEmpty)
            }
            #expect(task.invocations.allSatisfy { $0.executable.hasPrefix("/") })
            #expect(task.timeout > 0)
        }
    }

    @Test func adminTasksUseTheHelperMap() {
        #expect(MaintenanceCatalog.task(.flushDNS).helperOperation == .flushDNS)
        #expect(MaintenanceCatalog.task(.rebuildSpotlight).helperOperation == .rebuildSpotlight)
        #expect(MaintenanceCatalog.task(.runPeriodic).helperOperation == .runPeriodic)
        #expect(MaintenanceCatalog.task(.thinLocalSnapshots).helperOperation == .thinLocalSnapshots(bytes: MaintenanceCatalog.defaultThinBytes))
        let custom = MaintenanceCatalog.thinLocalSnapshots(bytes: 5_000_000_000)
        #expect(custom.commandLine == "/usr/bin/tmutil thinlocalsnapshots / 5000000000 4")
    }

    @Test func availabilityFollowsTheExecutables() {
        let periodic = MaintenanceCatalog.task(.runPeriodic)
        #expect(periodic.availability(executableExists: { $0 != "/usr/sbin/periodic" }) == .unavailable(.toolMissing("/usr/sbin/periodic")))
        #expect(periodic.availability(executableExists: { _ in true }) == .available)
        let flush = MaintenanceCatalog.task(.flushDNS)
        #expect(flush.availability(executableExists: { $0 != "/usr/bin/killall" }) == .unavailable(.toolMissing("/usr/bin/killall")))
    }
}

/// A helper stand-in that records operations and returns a canned response.
final class FakeHelper: HelperPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var _ops: [HelperOperation] = []
    let result: Result<HelperResponse, HelperClientError>
    var ops: [HelperOperation] { lock.withLock { _ops } }

    init(_ result: Result<HelperResponse, HelperClientError>) { self.result = result }

    func perform(_ op: HelperOperation) async throws -> HelperResponse {
        lock.withLock { _ops.append(op) }
        return try result.get()
    }
}

func collect(_ stream: AsyncStream<MaintenanceEvent>) async -> [MaintenanceEvent] {
    var events: [MaintenanceEvent] = []
    for await event in stream { events.append(event) }
    return events
}

func outputs(_ events: [MaintenanceEvent]) -> [String] {
    events.compactMap { if case .output(let s) = $0 { return s }; return nil }
}

func exitCode(_ events: [MaintenanceEvent]) -> Int32? {
    if case .finished(let code, let duration) = events.last, duration >= 0 { return code }
    return nil
}

@Suite("MaintenanceRunner")
struct MaintenanceRunnerTests {
    @Test func userTaskStreamsLinesAndFinishesWithExitCode() async {
        let runner = RecordingCommandRunner { _, _ in CommandResult(exitCode: 0, stdout: "Started file system verification\nChecking volume\nFinished", stderr: "") }
        var maintenance = MaintenanceRunner(runner: runner, helper: nil)
        maintenance.executableExists = { _ in true }
        let events = await collect(maintenance.run(MaintenanceCatalog.task(.verifyStartupDisk)))
        #expect(outputs(events) == ["Started file system verification", "Checking volume", "Finished"])
        #expect(exitCode(events) == 0)
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].0 == "/usr/sbin/diskutil" && runner.calls[0].1 == ["verifyVolume", "/"])
    }

    @Test func userTaskRunsExactlyItsCommandLine() async {
        for task in MaintenanceCatalog.all where !task.needsAdmin {
            let runner = RecordingCommandRunner()
            var maintenance = MaintenanceRunner(runner: runner, helper: nil)
            maintenance.executableExists = { _ in true }
            _ = await collect(maintenance.run(task))
            #expect(CommandLineFormatter.join(runner.calls.map { (executable: $0.0, arguments: $0.1) }) == task.commandLine)
        }
    }

    @Test func userTaskFailureReportsTheExitCode() async {
        let runner = RecordingCommandRunner { _, _ in CommandResult(exitCode: 2, stdout: "", stderr: "") }
        var maintenance = MaintenanceRunner(runner: runner, helper: nil)
        maintenance.executableExists = { _ in true }
        let events = await collect(maintenance.run(MaintenanceCatalog.task(.clearFontCaches)))
        #expect(exitCode(events) == 2)
    }

    @Test func userTaskTimeoutIsReported() async {
        let runner = RecordingCommandRunner { _, _ in CommandResult(exitCode: 15, stdout: "partial", stderr: "", timedOut: true) }
        var maintenance = MaintenanceRunner(runner: runner, helper: nil)
        maintenance.executableExists = { _ in true }
        let events = await collect(maintenance.run(MaintenanceCatalog.task(.rebuildLaunchServices)))
        #expect(outputs(events) == ["partial"])
        #expect(events.contains(.failed(.timedOut)))
        #expect(exitCode(events) == 15)
    }

    @Test func adminTaskGoesThroughTheHelper() async {
        let helper = FakeHelper(.success(HelperResponse(exitCode: 0, output: "flushed\nrestarted\n")))
        let runner = RecordingCommandRunner()
        var maintenance = MaintenanceRunner(runner: runner, helperPerformer: helper)
        maintenance.executableExists = { _ in true }
        let events = await collect(maintenance.run(MaintenanceCatalog.task(.flushDNS)))
        #expect(helper.ops == [.flushDNS])
        #expect(runner.calls.isEmpty)
        #expect(outputs(events) == ["flushed", "restarted"])
        #expect(exitCode(events) == 0)
    }

    @Test func adminTaskReportsRejectionAndHelperErrors() async {
        var rejected = MaintenanceRunner(runner: RecordingCommandRunner(), helperPerformer: FakeHelper(.success(.rejected(.invalidByteCount))))
        rejected.executableExists = { _ in true }
        let r = await collect(rejected.run(MaintenanceCatalog.thinLocalSnapshots(bytes: 1)))
        #expect(r.contains(.failed(.rejected(.invalidByteCount))))
        #expect(exitCode(r) == 64)

        var broken = MaintenanceRunner(runner: RecordingCommandRunner(), helperPerformer: FakeHelper(.failure(.timedOut)))
        broken.executableExists = { _ in true }
        let b = await collect(broken.run(MaintenanceCatalog.task(.rebuildSpotlight)))
        #expect(b == [.failed(.helper(.timedOut))] + [b.last!])
        #expect(exitCode(b) == MaintenanceRunner.notRunExitCode)
    }

    @Test func adminTaskWithoutHelper() async {
        var maintenance = MaintenanceRunner(runner: RecordingCommandRunner(), helper: nil)
        maintenance.executableExists = { _ in true }
        let events = await collect(maintenance.run(MaintenanceCatalog.task(.rebuildSpotlight)))
        #expect(events.first == .failed(.helperMissing))
        #expect(exitCode(events) == MaintenanceRunner.notRunExitCode)
    }

    @Test func unavailableTaskRunsNothing() async {
        let helper = FakeHelper(.success(HelperResponse(exitCode: 0, output: "")))
        var maintenance = MaintenanceRunner(runner: RecordingCommandRunner(), helperPerformer: helper)
        maintenance.executableExists = { $0 != "/usr/sbin/periodic" }
        let events = await collect(maintenance.run(MaintenanceCatalog.task(.runPeriodic)))
        #expect(events.first == .failed(.unavailable(.toolMissing("/usr/sbin/periodic"))))
        #expect(helper.ops.isEmpty)
        #expect(exitCode(events) == MaintenanceRunner.notRunExitCode)
    }

    @Test func lineSplitterJoinsChunks() {
        let splitter = LineSplitter()
        #expect(splitter.feed("ab") == [])
        #expect(splitter.feed("c\nde") == ["abc"])
        #expect(splitter.feed("\r\n\nf") == ["de", ""])
        #expect(splitter.flush() == "f")
        #expect(splitter.flush() == nil)
    }
}

@Suite("HelperStatus and readers")
struct HelperStatusTests {
    @Test func mapsServiceManagementStatus() {
        #expect(HelperStatus(.notRegistered) == .notRegistered)
        #expect(HelperStatus(.enabled) == .enabled)
        #expect(HelperStatus(.requiresApproval) == .requiresApproval)
        #expect(HelperStatus(.notFound) == .notFound)
    }

    @Test func backgroundItemsReaderUsesSfltoolAsTheUser() async throws {
        let url = try #require(Bundle.module.url(forResource: "dumpbtm", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let runner = RecordingCommandRunner { _, _ in CommandResult(exitCode: 0, stdout: text, stderr: "") }
        let records = await BackgroundItemsReader.read(runner: runner)
        #expect(records?.count == 3)
        #expect(runner.calls.first?.0 == "/usr/bin/sfltool" && runner.calls.first?.1 == ["dumpbtm"])

        let failing = RecordingCommandRunner { _, _ in CommandResult(exitCode: 1, stdout: "", stderr: "Operation not permitted") }
        #expect(await BackgroundItemsReader.read(runner: failing) == nil)

        let helper = FakeHelper(.success(HelperResponse(exitCode: 0, output: text)))
        #expect(try await BackgroundItemsReader.read(helper: helper).count == 3)
        #expect(helper.ops == [.dumpBackgroundItems])
    }
}
