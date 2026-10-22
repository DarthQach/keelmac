import Foundation
import SafetyKit
import Testing
@testable import AppsKit

/// Read-only run against this Mac. Skipped unless KEELMAC_LIVE=1. Lists and measures; never removes or changes
/// anything (launchctl is only asked `print-disabled`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KEELMAC_LIVE"] == "1"))
struct LiveTests {
    static func mb(_ b: Int64?) -> String { String(format: "%.1f MB", Double(b ?? 0) / 1_000_000) }

    @Test func liveSummary() async throws {
        let home = NSHomeDirectory()
        let start = Date()
        let apps = await AppInventory.scan(folders: AppInventory.defaultFolders(home: home))
        let scanSeconds = Date().timeIntervalSince(start)
        print("LIVE apps: \(apps.count) in \(String(format: "%.1f", scanSeconds)) s, total \(Self.mb(apps.reduce(0) { $0 + ($1.bytes ?? 0) }))")
        print("LIVE with team id: \(apps.filter { $0.teamID != nil }.count), apple: \(apps.filter(\.isApple).count), with lastUsed: \(apps.filter { $0.lastUsed != nil }.count)")
        for app in apps.sorted(by: { ($0.bytes ?? 0) > ($1.bytes ?? 0) }).prefix(10) {
            print("LIVE   \(app.name) | \(app.bundleID ?? "-") | \(app.teamID ?? "-") | \(Self.mb(app.bytes)) | \(app.lastUsed.map { "\($0)" } ?? "-")")
        }
        #expect(!apps.isEmpty)
        #expect(!apps.contains { $0.path.hasPrefix("/System/") })

        let picks = ProcessInfo.processInfo.environment["KEELMAC_LIVE_APPS"]?.split(separator: ",").map(String.init)
            ?? ["com.microsoft.VSCode", "com.google.Chrome", "com.tinyspeck.slackmacgap"]
        for bid in picks {
            guard let app = apps.first(where: { $0.bundleID == bid }) else { print("LIVE match \(bid): not installed"); continue }
            let t0 = Date()
            let files = RelatedFileMatcher.find(for: app, home: home, installed: apps)
            print("LIVE match \(app.name) (\(bid)): \(files.count) files, \(Self.mb(files.reduce(0) { $0 + $1.bytes })) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
            for f in files.prefix(25) {
                print("LIVE   \(f.location.rawValue) \(f.reason.rawValue)\(f.isShared ? " SHARED" : "")\(f.needsHelper ? " HELPER" : "") \(Self.mb(f.bytes)) \(f.path)")
            }
        }

        print("LIVE spotlight com.tinyspeck.slackmacgap: \(Spotlight.bundles(withID: "com.tinyspeck.slackmacgap"))")
        let t1 = Date()
        let orphans = OrphanFinder.find(home: home, installed: apps)
        print("LIVE orphans: \(orphans.count) groups, \(Self.mb(orphans.reduce(0) { $0 + $1.bytes })) in \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
        for g in orphans.prefix(60) {
            print("LIVE   \(g.id) \"\(g.displayName)\" \(Self.mb(g.bytes)) \(g.files.map { $0.location.rawValue }.joined(separator: ","))")
        }
        #expect(!orphans.contains { Identifiers.isApple($0.id) })
        let installedIDs = Set(apps.compactMap { $0.bundleID?.lowercased() })
        #expect(!orphans.contains { installedIDs.contains($0.id.lowercased()) })

        let store = LaunchItemStore(home: home, uid: getuid(), runner: ProcessCommandRunner(), installed: apps)
        let items = await store.list()
        print("LIVE launch items: \(items.count) (user \(items.filter { $0.domain == .userAgent }.count), global agents \(items.filter { $0.domain == .globalAgent }.count), daemons \(items.filter { $0.domain == .globalDaemon }.count)), disabled \(items.filter(\.isDisabled).count), orphans \(items.filter { !$0.ownerInstalled }.count)")
        for i in items {
            print("LIVE   [\(i.domain.rawValue)] \(i.label) owner=\(i.ownerName ?? "-") installed=\(i.ownerInstalled) disabled=\(i.isDisabled) schedule=\(i.schedule) program=\(i.program ?? "-")")
        }
    }
}
