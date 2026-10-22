import Foundation
import Testing
@testable import ScanKit

@Suite("Large files and System Data")
struct LargeFilesAndSystemDataTests {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let gb: Int64 = 1_000_000_000

    func tree() -> ScanTree {
        let monthsAgo = { (m: Double) in Date(timeIntervalSince1970: 1_760_000_000 - m * 30 * 86_400) }
        return makeTree([
            ("Movies", true, 0, 0, monthsAgo(1)),
            ("Movies/old.mov", false, 2 * gb, 1, monthsAgo(24)),
            ("Movies/recent.mov", false, 3 * gb / 2, 1, monthsAgo(24)),
            ("Downloads", true, 0, 0, monthsAgo(1)),
            ("Downloads/installer.dmg", false, 600_000_000, 1, monthsAgo(12)),
            ("Downloads/neverOpened.iso", false, 5 * gb, 1, monthsAgo(9)),
            ("Downloads/clip.mp4", false, 120_000_000, 1, monthsAgo(1)),
        ])
    }

    @Test func filtersBySizeAndLastOpened() {
        let t = tree()
        let opened: [String: Date] = [
            "/R/Movies/old.mov": Date(timeIntervalSince1970: 1_760_000_000 - 300 * 86_400),
            "/R/Movies/recent.mov": Date(timeIntervalSince1970: 1_760_000_000 - 5 * 86_400),
            "/R/Downloads/installer.dmg": Date(timeIntervalSince1970: 1_760_000_000 - 400 * 86_400),
        ]
        let sixMonths = now.addingTimeInterval(-182 * 86_400)
        var asked: [String] = []
        let result = LargeFileFinder.find(in: t, minBytes: gb, notOpenedSince: sixMonths) { asked.append($0); return opened[$0] }
        // > 1 GB and not opened for 6 months: old.mov (opened 10 months ago) and neverOpened.iso (falls back to modified, 9 months).
        #expect(result.map(\.path) == ["/R/Downloads/neverOpened.iso", "/R/Movies/old.mov"])
        #expect(result[0].lastOpened == nil)
        #expect(result[1].lastOpened == opened["/R/Movies/old.mov"])
        #expect(result[1].bytes == 2 * gb)
        #expect(!asked.contains("/R/Downloads/clip.mp4")) // below minBytes: no lookup

        let all = LargeFileFinder.find(in: t, minBytes: 500_000_000, notOpenedSince: nil) { opened[$0] }
        #expect(all.map(\.bytes) == [5 * gb, 2 * gb, 3 * gb / 2, 600_000_000])
        #expect(all.allSatisfy { $0.id == $0.path })
    }

    @Test func spotlightFallsBackToAccessDate() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.file("x.bin", bytes: 10)
        let atime = Date(timeIntervalSince1970: 1_500_000_000)
        var times = [timeval(tv_sec: 1_500_000_000, tv_usec: 0), timeval(tv_sec: 1_500_000_000, tv_usec: 0)]
        #expect(utimes(f.path("x.bin"), &times) == 0)
        let date = try #require(LargeFileFinder.spotlightLastOpened(f.path("x.bin")))
        #expect(abs(date.timeIntervalSince(atime)) < 1 || date > atime) // Spotlight may know a later use date
        #expect(LargeFileFinder.spotlightLastOpened(f.path("missing")) == nil)
    }

    @Test func snapshotParsing() {
        let list = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-20-101500.local
        com.apple.TimeMachine.2026-10-21-101500.local
        """
        let names = SystemDataBreakdown.parseSnapshotList(list)
        #expect(names == ["com.apple.TimeMachine.2026-10-20-101500.local", "com.apple.TimeMachine.2026-10-21-101500.local"])
        #expect(SystemDataBreakdown.parseSnapshotList("Snapshots for disk /:\n").isEmpty)

        let noSizes = """
        Snapshots for disk3s5 (2 found)
        |
        +-- 6C9C2B1E-0000-0000-0000-000000000001
        |   Name:        com.apple.TimeMachine.2026-10-20-101500.local
        |   XID:         123
        |   Purgeable:   Yes
        """
        #expect(SystemDataBreakdown.parseSnapshotSizes(noSizes, names: names) == nil)
        let withSizes = """
        +-- A
        |   Name:        com.apple.TimeMachine.2026-10-20-101500.local
        |   Size:        1.2 GB (1200000000 Bytes)
        +-- B
        |   Name:        com.apple.TimeMachine.2026-10-21-101500.local
        |   Size:        300.0 MB (300000000 Bytes)
        +-- C
        |   Name:        com.apple.os.update-XYZ
        |   Size:        9.0 GB (9000000000 Bytes)
        """
        #expect(SystemDataBreakdown.parseSnapshotSizes(withSizes, names: names) == 1_500_000_000)
    }

    @Test func measuresFixtureLocations() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.file("Library/Caches/com.example/blob", bytes: 70_000)
        try f.file("Library/Caches/other", bytes: 5_000)
        try f.file("Library/Logs/app.log", bytes: 9_000)
        let calls = CallLog()
        let runner = ScanCommandRunner { exe, args in
            calls.append(exe, args)
            if exe == "/usr/bin/tmutil" {
                return .init(exitCode: 0, stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-20-101500.local\n")
            }
            return .init(exitCode: 0, stdout: "Name: com.apple.TimeMachine.2026-10-20-101500.local\nPurgeable: Yes\n")
        }
        let locs = SystemDataBreakdown.locations(home: f.root, userTempRoot: nil)
        let items = await SystemDataBreakdown.measure(locations: locs, runner: runner)

        #expect(Set(items.map(\.kind)) == Set(SystemDataKind.allCases).subtracting([.other]))
        #expect(items.map(\.kind) == SystemDataKind.allCases.filter { $0 != .other })
        let caches = try #require(items.first { $0.kind == .appCaches })
        #expect(caches.bytes == f.allocated("Library/Caches/com.example/blob") + f.allocated("Library/Caches/other"))
        #expect(caches.cleanupCategory == "userCaches")
        #expect(caches.paths == [f.path("Library/Caches")])
        let sims = try #require(items.first { $0.kind == .simulators })
        #expect(sims.bytes == 0 && !sims.needsFullDiskAccess) // missing folder measures 0
        let snaps = try #require(items.first { $0.kind == .localSnapshots })
        #expect(snaps.paths == ["com.apple.TimeMachine.2026-10-20-101500.local"])
        #expect(snaps.bytes == nil) // diskutil reported no sizes
        #expect(calls.all.map(\.0) == ["/usr/bin/tmutil", "/usr/sbin/diskutil"])
        #expect(calls.all.first?.1 == ["listlocalsnapshots", "/"])
        #expect(calls.all.last?.1 == ["apfs", "listSnapshots", "/"])
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func unreadableLocationIsFlagged() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.file("locked/a", bytes: 1000)
        chmod(f.path("locked"), 0o000)
        let m = await SystemDataBreakdown.measurePath(f.path("locked"))
        #expect(m.bytes == nil)
        // A POSIX permission denial (EACCES) is not something Full Disk Access fixes.
        #expect(!m.privacyBlocked)
        let missing = await SystemDataBreakdown.measurePath(f.path("nope"))
        #expect(missing.bytes == 0)
    }

    @Test func userTempRootIsUnderVarFolders() {
        let root = SystemDataBreakdown.userTempRoot()
        #expect(root == nil || root!.hasPrefix("/private/var/folders/"))
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, [String])] = []
    func append(_ exe: String, _ args: [String]) { lock.withLock { calls.append((exe, args)) } }
    var all: [(String, [String])] { lock.withLock { calls } }
}
