import Foundation
import Testing
@testable import SafetyKit

/// Builds a throwaway home folder in the temp directory. Nothing here touches the real home or Trash.
struct FixtureHome {
    let root: URL
    let home: URL
    let trash: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("sr-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        trash = root.appendingPathComponent("trash")
        for dir in ["Library/Caches", "Library/Mail", "Downloads"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 16) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func remover(mode: DeleteMode = .trash, whitelist: Whitelist = Whitelist()) -> SafeRemover {
        var r = SafeRemover(pathGuard: PathGuard(home: home.path, userName: "carlos", uid: 501, whitelist: whitelist), mode: mode, context: .cleanup)
        let trashDir = trash
        r.trasher = { url in try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)) }
        return r
    }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(rel).path) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("SafeRemover")
struct SafeRemoverTests {
    @Test func trashesOnlyRequestedItems() throws {
        let f = try FixtureHome(); defer { f.cleanup() }
        let a = try f.file("Library/Caches/com.a/data")
        try f.file("Library/Caches/com.b/data")
        let out = f.remover().remove([RemovalRequest(path: a.deletingLastPathComponent().path, bytes: 16)])
        #expect(out.map(\.result) == [.trashed])
        #expect(!f.exists("Library/Caches/com.a"))
        #expect(f.exists("Library/Caches/com.b/data"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).count == 1)
    }

    @Test func permanentDelete() throws {
        let f = try FixtureHome(); defer { f.cleanup() }
        let a = try f.file("Downloads/Xcode.dmg")
        let out = f.remover(mode: .permanent).remove([RemovalRequest(path: a.path, bytes: 16)])
        #expect(out.first?.result == .deleted)
        #expect(!f.exists("Downloads/Xcode.dmg"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).isEmpty)
    }

    @Test func refusesProtectedAndKeepsThem() throws {
        let f = try FixtureHome(); defer { f.cleanup() }
        let mail = try f.file("Library/Mail/V10/msg.emlx")
        let out = f.remover(mode: .permanent).remove([
            RemovalRequest(path: mail.path, bytes: 16),
            RemovalRequest(path: f.home.appendingPathComponent("Library/Caches").path, bytes: 0),
        ])
        #expect(out.map(\.result) == [.refused, .refused])
        #expect(f.exists("Library/Mail/V10/msg.emlx"))
        #expect(f.exists("Library/Caches"))
    }

    @Test func skipsWhitelisted() throws {
        let f = try FixtureHome(); defer { f.cleanup() }
        let keep = try f.file("Library/Caches/com.spotify.client/a")
        let r = f.remover(mode: .permanent, whitelist: Whitelist(["~/Library/Caches/com.spotify.client"]))
        let out = r.remove([RemovalRequest(path: keep.deletingLastPathComponent().path, bytes: 1)])
        #expect(out.first?.result == .skipped)
        #expect(out.first?.refusal == .whitelisted)
        #expect(f.exists("Library/Caches/com.spotify.client/a"))
    }

    @Test func skipsItemsChangedSincePreview() throws {
        let f = try FixtureHome(); defer { f.cleanup() }
        let a = try f.file("Library/Caches/com.c/data")
        let old = Date().addingTimeInterval(-3600)
        let out = f.remover(mode: .permanent).remove([RemovalRequest(path: a.path, bytes: 16, expectedModificationDate: old)])
        #expect(out.first?.refusal == .changedSincePreview)
        #expect(f.exists("Library/Caches/com.c/data"))
    }

    @Test func missingItemIsSkipped() throws {
        let f = try FixtureHome(); defer { f.cleanup() }
        let out = f.remover().remove([RemovalRequest(path: f.home.appendingPathComponent("Library/Caches/gone").path, bytes: 1)])
        #expect(out.first?.refusal == .notFound)
    }

    @Test func entriesAndExport() throws {
        let outcomes = [
            RemovalOutcome(path: "/Users/c/Library/Caches/a,b", bytes: 2048, result: .trashed, reason: nil, refusal: nil),
            RemovalOutcome(path: "/Users/c/Library/Caches/x", bytes: 10, result: .skipped, reason: "Whitelisted", refusal: .whitelisted),
        ]
        let entries = SafeRemover.entries(outcomes, batchID: UUID(), kind: .cleanup, title: "Cleanup", date: Date(timeIntervalSince1970: 0))
        let csv = OperationLogExporter.csv(entries)
        #expect(csv.split(separator: "\n").count == 3)
        #expect(csv.contains("\"/Users/c/Library/Caches/a,b\""))
        let md = OperationLogExporter.markdown(entries)
        #expect(md.contains("| 1970-01-01T00:00:00Z | Cleanup | `/Users/c/Library/Caches/a,b` |"))
        let json = try OperationLogExporter.export(entries, as: .json)
        let back = try { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return try d.decode([OperationEntry].self, from: json) }()
        #expect(back.count == 2)
    }

    @Test func inMemoryLog() async {
        let log = InMemoryOperationLog()
        await log.record([OperationEntry(batchID: UUID(), kind: .cleanup, title: "t", path: "/p", bytes: 1, result: .trashed)])
        #expect(await log.entries.count == 1)
    }
}

@Suite("CommandRunner")
struct CommandRunnerTests {
    @Test func runsWithArgumentsNoShell() async {
        let r = await ProcessCommandRunner().run("/bin/echo", ["a; rm -rf /tmp/nothing"])
        #expect(r.exitCode == 0)
        #expect(r.stdout == "a; rm -rf /tmp/nothing\n")
    }

    @Test func missingExecutable() async {
        let r = await ProcessCommandRunner().run("/no/such/tool", [])
        #expect(r.exitCode == 127)
    }

    @Test func timeout() async {
        let r = await ProcessCommandRunner().run("/bin/sleep", ["5"], timeout: 0.3)
        #expect(r.timedOut)
    }
}
