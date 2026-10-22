import Foundation
import Testing
import SafetyKit
import HelperShared
@testable import HelperCore

/// A throwaway home and trash folder in the temp directory. Nothing touches the real home, Trash or /Library.
struct TempFixture {
    let root: URL
    let home: URL
    let trash: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("mk-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        trash = root.appendingPathComponent("trash/KeelMac")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ rel: String, contents: String = "x") throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Records every URL the remover tries to trash, without touching it.
final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func record(_ url: URL) { lock.withLock { _urls.append(url) } }
}

func helperRemover(home: String = "/Users/carlos", recorder: TrashRecorder) -> SafeRemover {
    var remover = SafeRemover(pathGuard: PathGuard(home: home, userName: "carlos", uid: 501), mode: .trash, context: .helper)
    remover.trasher = { recorder.record($0) }
    return remover
}

@Suite("HelperExecutor")
struct HelperExecutorTests {
    @Test func flushDNSRunsBothCommandsInOrder() async {
        let runner = RecordingCommandRunner { _, _ in CommandResult(exitCode: 0, stdout: "ok", stderr: "") }
        let executor = HelperExecutor(runner: runner, remover: helperRemover(recorder: TrashRecorder()), clientUID: 501)
        let response = await executor.perform(.flushDNS)
        #expect(response.succeeded)
        #expect(runner.calls.map(\.0) == ["/usr/bin/dscacheutil", "/usr/bin/killall"])
        #expect(runner.calls.map(\.1) == [["-flushcache"], ["-HUP", "mDNSResponder"]])
        #expect(response.output == "ok\nok\n")
    }

    @Test func everyOperationRunsExactlyItsMappedCommands() async {
        let ops: [HelperOperation] = [.flushDNS, .rebuildSpotlight, .runPeriodic, .thinLocalSnapshots(bytes: 5_000_000_000), .dumpBackgroundItems]
            + LaunchdAction.allCases.map { .launchd(label: "com.example.d", plistPath: "/Library/LaunchDaemons/com.example.d.plist", action: $0) }
        for op in ops {
            let runner = RecordingCommandRunner()
            let executor = HelperExecutor(runner: runner, remover: helperRemover(recorder: TrashRecorder()), clientUID: 501)
            _ = await executor.perform(op)
            let expected = HelperCommandMap.invocations(for: op, clientUID: 501)
            #expect(runner.calls.map(\.0) == expected.map(\.executable), "\(op)")
            #expect(runner.calls.map(\.1) == expected.map(\.arguments), "\(op)")
        }
    }

    @Test func failureStopsTheOperation() async {
        let runner = RecordingCommandRunner { exe, _ in
            exe == "/usr/bin/dscacheutil" ? CommandResult(exitCode: 3, stdout: "", stderr: "boom") : CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let response = await HelperExecutor(runner: runner, remover: helperRemover(recorder: TrashRecorder()), clientUID: 501).perform(.flushDNS)
        #expect(response.exitCode == 3)
        #expect(response.output == "boom\n")
        #expect(runner.calls.count == 1)
    }

    @Test func bestEffortFailureDoesNotFailTheOperation() async {
        // `bootout` of a job that isn't running fails; disabling still succeeded.
        let runner = RecordingCommandRunner { _, args in
            args.first == "bootout" ? CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service") : CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let op = HelperOperation.launchd(label: "com.example.d", plistPath: "/Library/LaunchDaemons/com.example.d.plist", action: .disable)
        let response = await HelperExecutor(runner: runner, remover: helperRemover(recorder: TrashRecorder()), clientUID: 501).perform(op)
        #expect(response.exitCode == 0)
        #expect(runner.calls.count == 2)
    }

    @Test func timeoutIsReported() async {
        let runner = RecordingCommandRunner { _, _ in CommandResult(exitCode: 15, stdout: "", stderr: "", timedOut: true) }
        let response = await HelperExecutor(runner: runner, remover: helperRemover(recorder: TrashRecorder()), clientUID: 501).perform(.rebuildSpotlight)
        #expect(response.timedOut && !response.succeeded)
    }

    @Test(arguments: [
        HelperOperation.launchd(label: "com.example.d; rm -rf /", plistPath: "/Library/LaunchDaemons/com.example.d.plist", action: .remove),
        .launchd(label: "com.example d", plistPath: "/Library/LaunchDaemons/com.example d.plist", action: .disable),
        .launchd(label: "../../etc/passwd", plistPath: "/Library/LaunchDaemons/x.plist", action: .disable),
        .launchd(label: "com.example.d", plistPath: "/Library/LaunchDaemons/../../System/Library/LaunchDaemons/com.example.d.plist", action: .remove),
        .launchd(label: "com.example.d", plistPath: "/System/Library/LaunchDaemons/com.example.d.plist", action: .disable),
        .launchd(label: "com.example.d", plistPath: "/Users/carlos/Library/LaunchAgents/com.example.d.plist", action: .remove),
        .launchd(label: "com.apple.Finder", plistPath: "/Library/LaunchAgents/com.apple.Finder.plist", action: .disable),
        .launchd(label: "com.example.d", plistPath: "/Library/LaunchDaemons/com.other.d.plist", action: .disable),
        .removeSystemItems(paths: []),
        .removeSystemItems(paths: ["/Library/Caches/../../System"]),
        .removeSystemItems(paths: ["Library/Caches/x"]),
        .thinLocalSnapshots(bytes: 0),
    ])
    func invalidRequestsRunNothing(_ op: HelperOperation) async {
        let runner = RecordingCommandRunner()
        let recorder = TrashRecorder()
        var executor = HelperExecutor(runner: runner, remover: helperRemover(recorder: recorder), clientUID: 501)
        executor.plistLabelReader = { _ in nil }
        let response = await executor.perform(op)
        #expect(response.rejection != nil, "\(op)")
        #expect(response.exitCode == HelperResponse.rejectedExitCode)
        #expect(runner.calls.isEmpty)
        #expect(recorder.urls.isEmpty)
    }

    @Test func removeSystemItemsRefusesHomeAndProtectedPaths() async {
        let recorder = TrashRecorder()
        let executor = HelperExecutor(runner: RecordingCommandRunner(), remover: helperRemover(recorder: recorder), clientUID: 501)
        let paths = [
            "/Users/carlos/Documents/taxes.pdf",          // the user's home: never through the helper
            "/Users/carlos/Library/Caches/com.example",
            "/Users/other/Library/Caches/x",               // another user's home
            "/System/Library/Caches/com.apple.x",          // protected
            "/usr/bin/true",
            "/Library/Keychains/System.keychain",
            "/Library/Caches",                              // a container folder itself
            "/Library/LaunchDaemons",
            "/private/var/db/x",
            "/Applications",
        ]
        let response = await executor.perform(.removeSystemItems(paths: paths))
        #expect(response.exitCode == 1)
        #expect(response.outcomes.count == paths.count)
        #expect(response.outcomes.allSatisfy { $0.result == .refused })
        #expect(response.outcomes[0].refusal == .outsideAllowedRoots)
        #expect(response.outcomes[2].refusal == .otherUserHome)
        #expect(response.outcomes[3].refusal == .protectedLocation)
        #expect(response.outcomes[6].refusal == .containerFolder)
        #expect(recorder.urls.isEmpty)
    }

    @Test func removeSystemItemsSkipsMissingItemsInHelperRoots() async {
        let recorder = TrashRecorder()
        let executor = HelperExecutor(runner: RecordingCommandRunner(), remover: helperRemover(recorder: recorder), clientUID: 501)
        let path = "/Library/Caches/mx.cvillegas.keelmac.tests.\(UUID().uuidString)"
        let response = await executor.perform(.removeSystemItems(paths: [path]))
        #expect(response.outcomes.first?.result == .skipped)
        #expect(response.outcomes.first?.refusal == .notFound)
        #expect(response.exitCode == 0)
        #expect(recorder.urls.isEmpty)
    }

    @Test func removeSystemItemsMovesAllowedItemsIntoTheInjectedTrashFolder() async throws {
        // /Library can't hold test fixtures, so this uses a temp home with the cleanup context: it proves the
        // executor → SafeRemover → UserTrashMover path moves (never deletes) and reports each item.
        let fx = try TempFixture()
        defer { fx.cleanup() }
        let a = try fx.file("Library/Caches/com.example/a.cache", contents: "aaa")
        let b = try fx.file("Library/Caches/b.log", contents: "bb")
        var remover = SafeRemover(pathGuard: PathGuard(home: fx.home.path, userName: "carlos", uid: 501), mode: .trash, context: .cleanup)
        let mover = UserTrashMover(folder: fx.trash)
        remover.trasher = { try mover.move($0) }
        let executor = HelperExecutor(runner: RecordingCommandRunner(), remover: remover, clientUID: 501)

        let response = await executor.perform(.removeSystemItems(paths: [a.deletingLastPathComponent().path, b.path, "/System/x"]))
        #expect(response.outcomes.map(\.result) == [.trashed, .trashed, .refused])
        #expect(response.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: fx.trash.appendingPathComponent("com.example/a.cache").path))
        #expect(try String(contentsOf: fx.trash.appendingPathComponent("b.log"), encoding: .utf8) == "bb")
    }

    @Test func launchdRemoveBootsOutThenTrashesThePlist() async {
        let recorder = TrashRecorder()
        let runner = RecordingCommandRunner()
        let plist = "/Library/LaunchDaemons/mx.cvillegas.keelmac.tests.\(UUID().uuidString.lowercased()).plist"
        let label = ((plist as NSString).lastPathComponent as NSString).deletingPathExtension
        let response = await HelperExecutor(runner: runner, remover: helperRemover(recorder: recorder), clientUID: 501)
            .perform(.launchd(label: label, plistPath: plist, action: .remove))
        #expect(runner.calls.map(\.1) == [["bootout", "system/\(label)"]])
        #expect(response.outcomes.map(\.path) == [plist])
        // The fixture plist doesn't exist, so the guard allowed it and the existence check skipped it.
        #expect(response.outcomes.first?.refusal == .notFound)
    }

    @Test func forClientBuildsAHelperContextRemover() {
        let executor = HelperExecutor.forClient(uid: getuid(), runner: RecordingCommandRunner())
        #expect(executor.remover.context == .helper)
        #expect(executor.remover.mode == .trash)
        #expect(executor.clientUID == getuid())
        #expect(executor.remover.pathGuard.uid == getuid())
        #expect(executor.remover.pathGuard.home == PathGuard.canonical(PathGuard.normalize(UserAccount(uid: getuid())!.home)))
    }

    @Test func readPlistLabel() throws {
        let fx = try TempFixture()
        defer { fx.cleanup() }
        let url = fx.root.appendingPathComponent("x.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.x"], format: .xml, options: 0)
        try data.write(to: url)
        #expect(HelperExecutor.readPlistLabel(url.path) == "com.example.x")
        let link = fx.root.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(HelperExecutor.readPlistLabel(link.path) == nil)
        #expect(HelperExecutor.readPlistLabel(fx.root.appendingPathComponent("missing.plist").path) == nil)
    }
}

@Suite("UserTrashMover")
struct UserTrashMoverTests {
    @Test func createsTheFolderAndAvoidsCollisions() throws {
        let fx = try TempFixture()
        defer { fx.cleanup() }
        let mover = UserTrashMover(folder: fx.trash)
        let first = try mover.move(try fx.file("one/report.log", contents: "1"))
        let second = try mover.move(try fx.file("two/report.log", contents: "2"))
        let third = try mover.move(try fx.file("three/report.log", contents: "3"))
        let dir = try mover.move(try fx.file("four/Cache/inner", contents: "4").deletingLastPathComponent())
        let dir2 = try mover.move(try fx.file("five/Cache/inner", contents: "5").deletingLastPathComponent())
        #expect(first.lastPathComponent == "report.log")
        #expect(second.lastPathComponent == "report 2.log")
        #expect(third.lastPathComponent == "report 3.log")
        #expect(dir.lastPathComponent == "Cache")
        #expect(dir2.lastPathComponent == "Cache 2")
        #expect(try String(contentsOf: second, encoding: .utf8) == "2")
        #expect(try String(contentsOf: dir2.appendingPathComponent("inner"), encoding: .utf8) == "5")
    }

    @Test func refusesWhenTheTrashFolderIsAFile() throws {
        let fx = try TempFixture()
        defer { fx.cleanup() }
        try FileManager.default.createDirectory(at: fx.trash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: fx.trash)
        let item = try fx.file("x.txt")
        #expect(throws: (any Error).self) { try UserTrashMover(folder: fx.trash).move(item) }
        #expect(FileManager.default.fileExists(atPath: item.path))
    }

    @Test func forUserPointsIntoTheUsersTrash() throws {
        let mover = try #require(UserTrashMover.forUser(uid: getuid()))
        #expect(mover.folder.path.hasSuffix("/.Trash/KeelMac"))
        #expect(mover.ownerUID == getuid())
        #expect(UserTrashMover.forUser(uid: 4_000_000_000) == nil)
    }
}
