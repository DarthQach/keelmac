import Foundation
import ReportKit

/// Startup volume capacity as Finder reports it.
enum StartupVolume {
    static func capacity() -> (total: Int64, available: Int64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return (total, available)
    }
}

/// Weekly storage snapshots, the "what grew" comparison and the weekly summary notification (C24, C25).
@MainActor
@Observable
final class SnapshotService {
    private(set) var snapshots: [SnapshotValue] = []
    private(set) var isTaking = false
    private(set) var loadError: String?
    private let store: SnapshotStore
    private var scheduler: NSBackgroundActivityScheduler?

    /// Supplied by the app: current battery max capacity and last measured reclaimable bytes.
    var batteryProvider: @MainActor () -> Double? = { nil }
    var reclaimableProvider: @MainActor () -> Int64 = { Int64(UserDefaults.standard.integer(forKey: "lastReclaimableBytes")) }

    init(store: SnapshotStore) { self.store = store }

    func load() async {
        do {
            snapshots = try await store.all()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func takeSnapshot() async -> SnapshotValue? {
        guard !isTaking else { return nil }
        isTaking = true
        defer { isTaking = false }
        let (total, available) = StartupVolume.capacity()
        let battery = batteryProvider()
        let reclaimable = reclaimableProvider()
        let snapshot = await Task.detached(priority: .utility) {
            await SnapshotTaker.take(home: NSHomeDirectory(), volumeTotal: total, volumeUsed: total - available, battery: battery,
                                     reclaimable: reclaimable) { SnapshotTaker.allocatedSize(of: $0) }
        }.value
        do {
            try await store.save(snapshot)
            await load()
            return snapshot
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    /// Checks every few hours whether this week's snapshot and summary are due (Monday 09:00 or later).
    func startWeeklySchedule() {
        guard scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: "mx.cvillegas.keelmac.weekly")
        s.repeats = true
        s.interval = 4 * 3600
        s.tolerance = 3600
        s.qualityOfService = .utility
        s.schedule { [weak self] done in
            Task { @MainActor in
                await self?.runWeeklyIfDue()
                done(.finished)
            }
        }
        scheduler = s
        Task { await runWeeklyIfDue() }
    }

    func runWeeklyIfDue(now: Date = Date()) async {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: "lastWeeklyReport") as? Date
        guard WeeklyReport.isDue(lastReport: last, now: now) else { return }
        if snapshots.isEmpty { await load() }
        let previous = snapshots.first
        guard let current = await takeSnapshot() else { return }
        defaults.set(now, forKey: "lastWeeklyReport")
        guard defaults.bool(forKey: Preferences.Key.weeklySummary) else { return }
        let report = WeeklyReport.make(current: current, previous: previous)
        await Notifier.shared.post(id: "weekly-\(Int(now.timeIntervalSince1970))", title: String(localized: "Your week on this Mac"),
                                   body: Self.summary(report), category: .weekly, url: URL(string: "keelmac://open/snapshots"))
    }

    static func summary(_ r: WeeklyReport) -> String {
        var parts: [String] = []
        if r.hasComparison {
            let amount = Format.bytes(abs(r.usedDelta))
            if let top = r.topGrowth.first, top.delta > 0 {
                let name = (top.path as NSString).lastPathComponent
                parts.append(r.usedDelta >= 0 ? String(localized: "\(amount) more used, mostly \(name).") : String(localized: "\(amount) less used."))
            } else {
                parts.append(r.usedDelta >= 0 ? String(localized: "\(amount) more used.") : String(localized: "\(amount) less used."))
            }
        } else {
            parts.append(String(localized: "First snapshot taken. Next week you’ll see what grew."))
        }
        if r.reclaimable > 0 { parts.append(String(localized: "\(Format.bytes(r.reclaimable)) can be cleaned.")) }
        if let battery = r.batteryNow { parts.append(String(localized: "Battery at \(Format.percent(battery / 100)).")) }
        return parts.joined(separator: " ")
    }

    func markdownReport(current: SnapshotValue, previous: SnapshotValue?) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return WeeklyReport.make(current: current, previous: previous).markdown(appVersion: version)
    }
}
