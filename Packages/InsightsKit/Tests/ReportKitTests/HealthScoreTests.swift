import Foundation
import Testing
@testable import ReportKit

private let total: Int64 = 1_000_000

private func inputs(
    used: Double = 0.5,
    warning: Double = 0,
    critical: Double = 0,
    battery: Double? = 100,
    reclaimable: Int64? = 0,
    startup: Int = 0,
    orphans: Int = 0
) -> HealthInputs {
    HealthInputs(
        sampledAt: Date(timeIntervalSince1970: 0),
        diskTotal: total,
        diskAvailable: total - Int64((Double(total) * used).rounded()),
        pressureWarningFraction: warning,
        pressureCriticalFraction: critical,
        batteryMaxCapacityPercent: battery,
        batteryCycles: battery == nil ? nil : 300,
        reclaimableBytes: reclaimable,
        startupItems: startup,
        orphanStartupItems: orphans
    )
}

private func points(_ kind: HealthFactorKind, _ i: HealthInputs) -> Int {
    HealthScore.compute(i).factor(kind)!.points
}

@Suite("HealthScore")
struct HealthScoreTests {
    @Test("Score bounds: a perfect Mac scores 100, the worst scores 0")
    func bounds() {
        let best = HealthScore.compute(inputs())
        #expect(best.score == 100)
        #expect(best.band == .good)
        #expect(best.topIssue == nil)
        let worst = HealthScore.compute(inputs(used: 1, warning: 1, critical: 1, battery: 50,
                                               reclaimable: total, startup: 40, orphans: 9))
        #expect(worst.score == 0)
        #expect(worst.band == .poor)
        #expect(worst.factors.map(\.id) == HealthFactorKind.allCases)
        #expect(worst.factors.map(\.maxPoints).reduce(0, +) == 100)
    }

    @Test("Disk free: 30 × clamp((0.97 − used) / 0.27)",
          arguments: [(0.0, 30), (0.70, 30), (0.835, 15), (0.916, 6), (0.97, 0), (1.0, 0)])
    func disk(used: Double, expected: Int) {
        #expect(points(.diskFree, inputs(used: used)) == expected)
    }

    @Test("Memory pressure: 20 × (1 − 0.5 × warning − critical)",
          arguments: [(0.0, 0.0, 20), (1.0, 0.0, 10), (0.0, 1.0, 0), (0.5, 0.5, 5), (0.2, 0.1, 16), (1.0, 1.0, 0)])
    func memory(warning: Double, critical: Double, expected: Int) {
        #expect(points(.memoryPressure, inputs(warning: warning, critical: critical)) == expected)
    }

    @Test("Battery: 20 × clamp((capacity − 70) / 25), full without a battery",
          arguments: [(100.0, 20), (95.0, 20), (82.5, 10), (70.0, 0), (55.0, 0), (93.75, 19)])
    func battery(capacity: Double, expected: Int) {
        #expect(points(.battery, inputs(battery: capacity)) == expected)
    }

    @Test("No battery scores full and says so")
    func noBattery() {
        let factor = HealthScore.compute(inputs(battery: nil)).factor(.battery)!
        #expect(factor.points == 20)
        #expect(factor.details == .battery(hasBattery: false, maxCapacityPercent: nil, cycles: nil))
    }

    @Test("Reclaimable: 20 × clamp(1 − bytes / (0.15 × disk))",
          arguments: [(Int64(0), 20), (Int64(75_000), 10), (Int64(150_000), 0), (Int64(900_000), 0), (Int64(7_500), 19)])
    func reclaimable(bytes: Int64, expected: Int) {
        #expect(points(.reclaimable, inputs(reclaimable: bytes)) == expected)
    }

    @Test("Unknown reclaimable scores full and flags a cleanup check")
    func reclaimableUnknown() {
        let report = HealthScore.compute(inputs(reclaimable: nil))
        let factor = report.factor(.reclaimable)!
        #expect(factor.points == 20)
        #expect(factor.isUnmeasured)
        #expect(report.needsCleanupCheck)
        #expect(!HealthScore.compute(inputs(reclaimable: 0)).needsCleanupCheck)
    }

    @Test("Startup items: 10 − 2 per orphan − 1 per 3 items above 12",
          arguments: [(0, 0, 10), (12, 0, 10), (14, 0, 10), (15, 0, 9), (21, 0, 7), (42, 0, 0), (60, 0, 0), (5, 2, 6), (15, 1, 7), (5, 5, 0)])
    func startup(items: Int, orphans: Int, expected: Int) {
        #expect(points(.startupItems, inputs(startup: items, orphans: orphans)) == expected)
        #expect(HealthScore.startupPoints(total: items, orphans: orphans) == expected)
    }

    @Test("Bands at 59, 60, 79 and 80")
    func bands() {
        #expect(HealthBand(score: 59) == .poor)
        #expect(HealthBand(score: 60) == .fair)
        #expect(HealthBand(score: 79) == .fair)
        #expect(HealthBand(score: 80) == .good)
        #expect(HealthBand(score: 0) == .poor)
        #expect(HealthBand(score: 100) == .good)
        // The same edges through compute: 30 + 10 + battery + reclaimable + 0.
        let s80 = HealthScore.compute(inputs(warning: 1, battery: 100, reclaimable: 0, orphans: 5))
        let s79 = HealthScore.compute(inputs(warning: 1, battery: 93.75, reclaimable: 0, orphans: 5))
        let s60 = HealthScore.compute(inputs(warning: 1, battery: 70, reclaimable: 0, orphans: 5))
        let s59 = HealthScore.compute(inputs(warning: 1, battery: 70, reclaimable: 7_500, orphans: 5))
        let scores: [Int] = [s80.score, s79.score, s60.score, s59.score]
        let bands: [HealthBand] = [s80.band, s79.band, s60.band, s59.band]
        #expect(scores == [80, 79, 60, 59])
        #expect(bands == [.good, .fair, .fair, .poor])
    }

    @Test("Each factor carries its fix route and raw details")
    func routesAndDetails() {
        let report = HealthScore.compute(inputs(used: 0.9, warning: 0.2, critical: 0.1, battery: 88,
                                                reclaimable: 30_000, startup: 15, orphans: 1))
        let routes = Dictionary(uniqueKeysWithValues: report.factors.map { ($0.id, $0.fix) })
        #expect(routes == [.diskFree: .storageMap, .memoryPressure: .monitor, .battery: .monitor,
                           .reclaimable: .cleanup, .startupItems: .loginItems])
        #expect(report.factor(.diskFree)?.details == .diskFree(totalBytes: total, availableBytes: 100_000,
                                                              usedFraction: 0.9, marginBytes: -50_000))
        #expect(report.factor(.memoryPressure)?.details == .memoryPressure(warningFraction: 0.2, criticalFraction: 0.1))
        #expect(report.factor(.battery)?.details == .battery(hasBattery: true, maxCapacityPercent: 88, cycles: 300))
        #expect(report.factor(.reclaimable)?.details == .reclaimable(bytes: 30_000, fractionOfDisk: 0.03))
        #expect(report.factor(.startupItems)?.details == .startupItems(total: 15, orphans: 1, overLimit: 3))
        // Disk lost the most points (8 of 30).
        #expect(report.topIssue?.id == .diskFree)
    }

    @Test("Out-of-range inputs are clamped")
    func clamping() {
        var i = inputs()
        i.diskAvailable = total * 2
        i.pressureWarningFraction = -3
        i.reclaimableBytes = -5
        i.startupItems = -1
        i.orphanStartupItems = -1
        #expect(HealthScore.compute(i).score == 100)
        var empty = inputs()
        empty.diskTotal = 0
        empty.diskAvailable = 0
        #expect(points(.diskFree, empty) == 0)
    }
}

@Suite("LoadLine")
struct LoadLineTests {
    @Test("Margin is 0.85 × total − used: positive above the line, negative below")
    func margin() {
        #expect(LoadLine.fraction == 0.85)
        #expect(LoadLine.marginBytes(total: 1_000, used: 850) == 0)
        #expect(LoadLine.marginBytes(total: 1_000, used: 800) == 50)
        #expect(LoadLine.marginBytes(total: 1_000, used: 900) == -50)
        #expect(LoadLine.marginBytes(total: 994_662_584_320, used: 600_000_000_000) > 0)
        #expect(LoadLine.marginBytes(total: 494_384_795_648, used: 480_000_000_000) < 0)
        #expect(LoadLine.lineBytes(total: 1_000) == 850)
    }
}
