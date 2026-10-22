import Foundation
import MetricsKit
import ReportKit

/// Builds Health Score inputs from live metrics plus the latest cleanup and login-item counts,
/// and caches them so the dashboard shows a score immediately at launch (FR-1).
@MainActor
@Observable
final class HealthService {
    private(set) var reclaimableBytes: Int64?
    private(set) var startupItems = 0
    private(set) var orphanStartupItems = 0
    private let cached: HealthInputs?

    init() {
        cached = UserDefaults.standard.data(forKey: Preferences.Key.healthCache).flatMap { try? JSONDecoder().decode(HealthInputs.self, from: $0) }
        refreshCounts()
    }

    func refreshCounts() {
        let d = UserDefaults.standard
        reclaimableBytes = d.object(forKey: "lastReclaimableBytes") == nil ? nil : Int64(d.integer(forKey: "lastReclaimableBytes"))
        startupItems = d.integer(forKey: "startupItemCount")
        orphanStartupItems = d.integer(forKey: "startupOrphanCount")
    }

    func recordReclaimable(_ bytes: Int64) {
        UserDefaults.standard.set(bytes, forKey: "lastReclaimableBytes")
        reclaimableBytes = bytes
    }

    func recordStartupItems(total: Int, orphans: Int) {
        UserDefaults.standard.set(total, forKey: "startupItemCount")
        UserDefaults.standard.set(orphans, forKey: "startupOrphanCount")
        startupItems = total
        orphanStartupItems = orphans
    }

    func inputs(metrics: MetricsMonitor) -> HealthInputs {
        if metrics.latest == nil, let cached { return cached }
        let disk = metrics.latest?.disk
        let fallback = disk == nil ? StartupVolume.capacity() : (total: 0, available: 0)
        let fractions = metrics.pressureFractions
        let battery = metrics.battery
        return HealthInputs(
            sampledAt: metrics.latest?.date ?? Date(),
            diskTotal: disk?.totalBytes ?? fallback.total,
            diskAvailable: disk?.availableBytes ?? fallback.available,
            pressureWarningFraction: fractions.warning,
            pressureCriticalFraction: fractions.critical,
            batteryMaxCapacityPercent: battery?.isPresent == true ? battery?.maxCapacityPercent : nil,
            batteryCycles: battery?.cycleCount,
            reclaimableBytes: reclaimableBytes,
            startupItems: startupItems,
            orphanStartupItems: orphanStartupItems)
    }

    func cache(_ inputs: HealthInputs) {
        UserDefaults.standard.set(try? JSONEncoder().encode(inputs), forKey: Preferences.Key.healthCache)
    }
}
