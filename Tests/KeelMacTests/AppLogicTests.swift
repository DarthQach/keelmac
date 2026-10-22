import CleanKit
import Foundation
import ReportKit
import SafetyKit
import Testing
@testable import KeelMac

@Suite("App logic")
@MainActor
struct AppLogicTests {
    @Test func menuBarItemsDecodeInOrderAndSkipUnknown() {
        #expect(MenuBarItem.decode("cpu,bogus,temperature") == [.cpu, .temperature])
        #expect(MenuBarItem.decode("") == [])
    }

    @Test func cleanupSelectionStates() {
        let model = CleanupModel(log: InMemoryOperationLog(), onReclaimable: { _ in })
        model.selected = ["a"]
        #expect(model.state(of: ["a", "b"]) == .mixed)
        model.toggle(["a", "b"])
        #expect(model.state(of: ["a", "b"]) == .on)
        model.toggle(["a", "b"])
        #expect(model.state(of: ["a", "b"]) == .off)
    }

    @Test func alertTextNamesTheRightScreen() {
        #expect(AlertNotifications.text(AlertEvent(kind: .diskLow, value: 5e9, threshold: 1e10)).2 == "cleanup")
        #expect(AlertNotifications.text(AlertEvent(kind: .memoryRed, value: 4, threshold: 5)).2 == "monitor")
        #expect(AlertNotifications.text(AlertEvent(kind: .temperatureHigh, value: 99, threshold: 95)).2 == "monitor")
    }

    @Test func weeklySummaryMentionsGrowthAndReclaimable() {
        let old = SnapshotValue(id: UUID(), date: Date(timeIntervalSince1970: 0), volumeTotal: 1_000, volumeUsed: 400,
                                batteryMaxCapacityPercent: 90, reclaimableBytes: 0, entries: ["/Users/c/Developer": 100])
        let new = SnapshotValue(id: UUID(), date: Date(timeIntervalSince1970: 604_800), volumeTotal: 1_000, volumeUsed: 500,
                                batteryMaxCapacityPercent: 89, reclaimableBytes: 50, entries: ["/Users/c/Developer": 200])
        let text = SnapshotService.summary(WeeklyReport.make(current: new, previous: old))
        #expect(text.contains("Developer"))
        #expect(!text.isEmpty)
    }

    @Test func removalOutcomeHelpers() {
        let outcomes = [RemovalOutcome(path: "/a", bytes: 10, result: .trashed, reason: nil, refusal: nil),
                        RemovalOutcome(path: "/b", bytes: 5, result: .skipped, reason: "Whitelisted", refusal: .whitelisted)]
        #expect(outcomes.bytesRemoved == 10)
        #expect(outcomes.removedCount == 1)
        #expect(outcomes.notRemoved.map(\.path) == ["/b"])
    }

    @Test func fileActionsGuardUsesWhitelistFromSettings() {
        let key = Preferences.Key.whitelist
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(["~/Library/Caches/com.example.keep"], forKey: key)
        let verdict = FileActions.pathGuard().verdict(for: NSHomeDirectory() + "/Library/Caches/com.example.keep/x", context: .cleanup)
        #expect(verdict == .refuse(.whitelisted))
    }
}
