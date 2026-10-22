import Foundation
import Testing
@testable import ReportKit

private func snapshot(_ date: Date, used: Int64, battery: Double?, reclaimable: Int64 = 0, _ entries: [String: Int64]) -> SnapshotValue {
    SnapshotValue(id: UUID(), date: date, volumeTotal: 1_000_000_000_000, volumeUsed: used,
                  batteryMaxCapacityPercent: battery, reclaimableBytes: reclaimable, entries: entries)
}

final class TempHome {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("InsightsKit-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func mkdir(_ rel: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
    }
    func write(_ rel: String, bytes: Int) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }
}

@Suite("Snapshots")
struct SnapshotTests {
    @Test("Folders: visible top-level home folders, then the large ~/Library children; never iCloud")
    func folders() throws {
        let home = try TempHome()
        for dir in ["Documents", "Downloads", "Developer", ".ssh", "Library/Caches", "Library/Developer",
                    "Library/Mobile Documents", "Library/Mail", "Library/Group Containers", "Elsewhere"] {
            try home.mkdir(dir)
        }
        try home.write("notes.txt", bytes: 10)
        try FileManager.default.createSymbolicLink(at: home.root.appendingPathComponent("LinkToElsewhere"),
                                                   withDestinationURL: home.root.appendingPathComponent("Elsewhere"))
        let base = home.root.path
        let folders = SnapshotTaker.folders(home: base + "/")
        #expect(folders == [
            "\(base)/Developer", "\(base)/Documents", "\(base)/Downloads", "\(base)/Elsewhere",
            "\(base)/Library/Developer", "\(base)/Library/Caches", "\(base)/Library/Group Containers",
        ])
    }

    @Test("Allocated size counts files, skips symlinks")
    func allocatedSize() throws {
        let home = try TempHome()
        try home.write("Docs/a.bin", bytes: 100_000)
        try home.write("Docs/sub/b.bin", bytes: 50_000)
        try home.write("Big/huge.bin", bytes: 2_000_000)
        try FileManager.default.createSymbolicLink(at: home.root.appendingPathComponent("Docs/link"),
                                                   withDestinationURL: home.root.appendingPathComponent("Big/huge.bin"))
        let size = SnapshotTaker.allocatedSize(of: home.root.appendingPathComponent("Docs").path)
        #expect(size >= 150_000)
        #expect(size < 1_000_000)
        #expect(SnapshotTaker.allocatedSize(of: home.root.appendingPathComponent("Docs/link").path) == 0)
        #expect(SnapshotTaker.allocatedSize(of: home.root.appendingPathComponent("missing").path) == 0)
    }

    @Test("Take measures every folder with the injected measure")
    func take() async throws {
        let home = try TempHome()
        try home.mkdir("Documents")
        try home.mkdir("Library/Caches")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let value = await SnapshotTaker.take(home: home.root.path, volumeTotal: 1000, volumeUsed: 600, battery: 91,
                                             reclaimable: 42, date: date) { path in Int64(path.count) }
        let docs = home.root.path + "/Documents", caches = home.root.path + "/Library/Caches"
        #expect(value.entries == [docs: Int64(docs.count), caches: Int64(caches.count)])
        #expect(value.date == date)
        #expect(value.volumeUsed == 600 && value.volumeTotal == 1000)
        #expect(value.batteryMaxCapacityPercent == 91 && value.reclaimableBytes == 42)
    }

    @Test("Diff: growth sorted by delta, new folders from 0, removed folders to 0, ties by path")
    func diff() {
        let old = snapshot(.distantPast, used: 0, battery: nil, ["/a": 100, "/b": 500, "/c": 300, "/gone": 50, "/same": 10, "/tie2": 0, "/tie1": 0])
        let new = snapshot(.distantFuture, used: 0, battery: nil, ["/a": 400, "/b": 200, "/c": 300, "/new": 250, "/same": 10, "/tie2": 5, "/tie1": 5])
        let changes = SnapshotDiff.compare(old: old, new: new)
        #expect(changes.map(\.id) == ["/a", "/new", "/tie1", "/tie2", "/c", "/same", "/gone", "/b"])
        #expect(changes.map(\.delta) == [300, 250, 5, 5, 0, 0, -50, -300])
        let added = changes.first { $0.id == "/new" }!
        #expect(added.isNew && added.oldBytes == nil && added.newBytes == 250)
        let removed = changes.first { $0.id == "/gone" }!
        #expect(removed.isRemoved && removed.newBytes == nil && removed.delta == -50)
    }
}

@Suite("WeeklyReport")
struct WeeklyReportTests {
    let utc = TimeZone(identifier: "UTC")!
    let previousDate = Date(timeIntervalSince1970: 1_791_796_800)  // 2026-10-12 09:20 UTC
    let currentDate = Date(timeIntervalSince1970: 1_792_401_600)   // 2026-10-19 09:20 UTC

    var previous: SnapshotValue {
        snapshot(previousDate, used: 412_300_000_000, battery: 92, reclaimable: 9_000_000_000, [
            "/Users/carlos/Developer": 40_000_000_000,
            "/Users/carlos/Library/Developer": 61_200_000_000,
            "/Users/carlos/Library/Caches": 8_400_000_000,
            "/Users/carlos/Downloads": 5_000_000_000,
            "/Users/carlos/Music": 2_000_000_000,
        ])
    }
    var current: SnapshotValue {
        snapshot(currentDate, used: 418_750_000_000, battery: 91, reclaimable: 12_400_000_000, [
            "/Users/carlos/Developer": 41_500_000_000,
            "/Users/carlos/Library/Developer": 66_900_000_000,
            "/Users/carlos/Library/Caches": 9_100_000_000,
            "/Users/carlos/Downloads": 4_200_000_000,
            "/Users/carlos/Movies": 3_300_000_000,
            "/Users/carlos/Docs | Old": 1_000_000,
        ])
    }

    @Test("Make: space change, battery trend, top growth, reclaimable")
    func make() {
        let report = WeeklyReport.make(current: current, previous: previous)
        #expect(report.usedDelta == 6_450_000_000)
        #expect(report.batteryNow == 91)
        #expect(report.batteryDelta == -1)
        #expect(report.reclaimable == 12_400_000_000)
        #expect(report.topGrowth.map(\.id) == ["/Users/carlos/Library/Developer", "/Users/carlos/Movies",
                                               "/Users/carlos/Developer", "/Users/carlos/Library/Caches",
                                               "/Users/carlos/Docs | Old"])
        #expect(report.topGrowth.allSatisfy { $0.delta > 0 })
        #expect(report.periodStart == previousDate && report.periodEnd == currentDate)

        let first = WeeklyReport.make(current: current, previous: nil)
        #expect(first.usedDelta == 0 && first.batteryDelta == nil && first.topGrowth.isEmpty && !first.hasComparison)
    }

    @Test("Markdown export matches the golden report")
    func goldenMarkdown() {
        let markdown = WeeklyReport.make(current: current, previous: previous).markdown(appVersion: "1.0.0", timeZone: utc)
        let golden = """
        # KeelMac weekly report

        **Period:** 2026-10-12 to 2026-10-19

        ## Summary

        | Item | Value |
        | --- | --- |
        | Space used | 418.75 GB of 1 TB |
        | Free space | 581.25 GB |
        | Change since last report | +6.45 GB |
        | Battery capacity | 91% (-1 pt) |
        | Reclaimable now | 12.4 GB |

        ## Top growing folders

        | Folder | Before | Now | Change |
        | --- | ---: | ---: | ---: |
        | `~/Library/Developer` | 61.2 GB | 66.9 GB | +5.7 GB |
        | `~/Movies` | new | 3.3 GB | +3.3 GB |
        | `~/Developer` | 40 GB | 41.5 GB | +1.5 GB |
        | `~/Library/Caches` | 8.4 GB | 9.1 GB | +700 MB |
        | `~/Docs \\| Old` | new | 1 MB | +1 MB |

        ---

        _Generated by KeelMac 1.0.0._

        """
        #expect(markdown == golden)
    }

    @Test("Markdown for a first report and for a desktop Mac")
    func firstReportMarkdown() {
        let desktop = snapshot(currentDate, used: 500_000_000_000, battery: nil, reclaimable: 0, ["/Users/c/Documents": 1])
        let markdown = WeeklyReport.make(current: desktop, previous: nil).markdown(appVersion: "1.0.0", timeZone: utc)
        #expect(markdown.contains("**Snapshot:** 2026-10-19 (first report, nothing to compare yet)"))
        #expect(markdown.contains("| Change since last report | n/a |"))
        #expect(markdown.contains("| Battery capacity | No battery |"))
        #expect(markdown.contains("No earlier snapshot to compare yet."))

        let flat = WeeklyReport.make(current: desktop, previous: desktop).markdown(appVersion: "1.0.0", timeZone: utc)
        #expect(flat.contains("No folder grew since the last report."))
        #expect(flat.contains("| Change since last report | 0 bytes |"))
        #expect(flat.contains("| Reclaimable now | 0 bytes |"))
    }

    // MARK: isDue

    func date(_ string: String, _ tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: string)!
    }

    @Test("isDue: Monday 09:00 or later, once per ISO week")
    func isDue() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        cal.firstWeekday = 1  // a Sunday-first calendar must not change the ISO week rule
        let d = { (s: String) in self.date(s, self.utc) }
        func due(_ last: String?, _ now: String) -> Bool { WeeklyReport.isDue(lastReport: last.map(d), now: d(now), calendar: cal) }

        #expect(!due(nil, "2026-10-19 08:59"))
        #expect(due(nil, "2026-10-19 09:00"))
        #expect(due("2026-10-16 10:00", "2026-10-19 09:30"))      // last Friday → due Monday
        #expect(due("2026-10-18 23:00", "2026-10-19 09:00"))      // Sunday belongs to the previous ISO week
        #expect(!due("2026-10-19 09:05", "2026-10-22 12:00"))     // already sent this week
        #expect(!due("2026-10-19 09:05", "2026-10-25 23:59"))     // Sunday is still the same week
        #expect(due("2026-10-19 09:05", "2026-10-26 09:00"))      // next Monday
        #expect(due("2026-10-19 08:00", "2026-10-19 09:00"))      // a report before 09:00 Monday doesn't count
        #expect(due("2026-10-12 09:00", "2026-10-21 18:00"))      // Monday missed (Mac asleep): due later that week
        // Year boundary: ISO week 53 of 2026 runs Mon 2026-12-28 → Sun 2027-01-03.
        #expect(!due("2026-12-28 10:00", "2027-01-01 12:00"))
        #expect(!due("2026-12-28 10:00", "2027-01-03 23:00"))
        #expect(due("2026-12-28 10:00", "2027-01-04 09:00"))
    }

    @Test("isDue follows the calendar's time zone")
    func isDueTimeZone() {
        let mexico = TimeZone(identifier: "America/Mexico_City")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = mexico
        // 2026-10-19 09:00 in Mexico City is 15:00 UTC.
        #expect(!WeeklyReport.isDue(lastReport: nil, now: date("2026-10-19 14:59", utc), calendar: cal))
        #expect(WeeklyReport.isDue(lastReport: nil, now: date("2026-10-19 15:00", utc), calendar: cal))
        #expect(WeeklyReport.dueMoment(weekOf: date("2026-10-22 12:00", mexico), calendar: cal) == date("2026-10-19 09:00", mexico))
    }
}
