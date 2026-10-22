import AppKit
import Foundation
import SafetyKit
import Testing
@testable import CleanKit

/// Plans against the real home folder, read-only. Never executes anything.
/// Run with `KEELMAC_LIVE=1 swift test --filter LivePlanTests`.
@Suite("Live plan (KEELMAC_LIVE=1)", .enabled(if: ProcessInfo.processInfo.environment["KEELMAC_LIVE"] == "1"))
struct LivePlanTests {
    @Test func planRealHomeReadOnly() async throws {
        let running = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        let env = CleanupEnvironment(hasFullDiskAccess: FullDiskAccess.isGranted(), runningBundleIDs: running)
        let planner = CleanupPlanner(rules: try RuleSet.bundled(), pathGuard: PathGuard(), environment: env, runner: ProcessCommandRunner())
        let clock = ContinuousClock()
        let start = clock.now
        let plan = await planner.plan()
        let elapsed = clock.now - start

        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        var lines = ["Live plan in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))), Full Disk Access: \(env.hasFullDiskAccess), running apps: \(running.count)"]
        for category in CleanupCategory.allCases {
            let groups = plan.groups(in: category)
            let total = groups.reduce(0) { $0 + $1.bytes }
            lines.append("\(category.rawValue): \(fmt.string(fromByteCount: total))")
            for g in groups {
                let skipped = g.skipped.isEmpty ? "" : ", skipped \(g.skipped.count) (\(fmt.string(fromByteCount: g.skipped.reduce(0) { $0 + $1.bytes })))"
                lines.append("  \(g.id) [\(g.status)] \(g.items.count) items, \(fmt.string(fromByteCount: g.bytes))\(g.selectedByDefault ? "" : ", unchecked")\(skipped), unreadable \(g.unreadableCount), refused \(g.refusedCount)")
            }
        }
        if let caches = plan.group(id: "user-caches") {
            lines.append("Largest app caches: " + caches.items.map { "\(($0.path as NSString).lastPathComponent) \(fmt.string(fromByteCount: $0.bytes))" }.joined(separator: ", "))
            lines.append("Skipped (app running): " + caches.skipped.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))
        }
        lines.append("Default selection: \(fmt.string(fromByteCount: plan.bytes(selected: plan.defaultSelection())))")
        print(lines.joined(separator: "\n"))

        // The same invariants as the fixture tests, on the real Mac.
        let guardian = PathGuard()
        let paths = plan.allItems.filter { !$0.isCommand }.map(\.path)
        #expect(Set(paths).count == paths.count)
        for item in plan.allItems where !item.isCommand {
            #expect(guardian.verdict(for: item.path, context: .cleanup).allowed, "\(item.path)")
        }
        var claims = ClaimSet()
        for p in paths.sorted(by: { $0.count < $1.count }) {
            #expect(!claims.conflicts(p), "\(p) overlaps another item")
            claims.claim(p)
        }
        #expect(elapsed < .seconds(60))
    }
}
