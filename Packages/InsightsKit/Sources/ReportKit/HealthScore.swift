import Foundation

/// Everything the Health Score is computed from. The app caches the last value (UserDefaults) so the
/// dashboard can show a score instantly at launch.
public struct HealthInputs: Sendable, Codable, Equatable {
    public var sampledAt: Date
    public var diskTotal: Int64
    public var diskAvailable: Int64
    /// Share of the recent window (0…1) spent at warning and critical memory pressure.
    public var pressureWarningFraction: Double
    public var pressureCriticalFraction: Double
    /// Nil on a Mac without a battery.
    public var batteryMaxCapacityPercent: Double?
    public var batteryCycles: Int?
    /// Nil until a cleanup check has measured it.
    public var reclaimableBytes: Int64?
    public var startupItems: Int
    public var orphanStartupItems: Int

    public init(
        sampledAt: Date,
        diskTotal: Int64,
        diskAvailable: Int64,
        pressureWarningFraction: Double,
        pressureCriticalFraction: Double,
        batteryMaxCapacityPercent: Double?,
        batteryCycles: Int?,
        reclaimableBytes: Int64?,
        startupItems: Int,
        orphanStartupItems: Int
    ) {
        self.sampledAt = sampledAt
        self.diskTotal = diskTotal
        self.diskAvailable = diskAvailable
        self.pressureWarningFraction = pressureWarningFraction
        self.pressureCriticalFraction = pressureCriticalFraction
        self.batteryMaxCapacityPercent = batteryMaxCapacityPercent
        self.batteryCycles = batteryCycles
        self.reclaimableBytes = reclaimableBytes
        self.startupItems = startupItems
        self.orphanStartupItems = orphanStartupItems
    }
}

public enum HealthFactorKind: String, Sendable, Codable, CaseIterable {
    case diskFree, memoryPressure, battery, reclaimable, startupItems
}

/// The screen a factor's fix button opens.
public enum FixRoute: String, Sendable, Codable {
    case storageMap, monitor, cleanup, loginItems
}

/// The raw values behind a factor, for the app's localized "why" sentence. No text is built here.
public enum HealthFactorDetails: Sendable, Codable, Equatable {
    /// `marginBytes` is `LoadLine.marginBytes`: positive = room left above the load line.
    case diskFree(totalBytes: Int64, availableBytes: Int64, usedFraction: Double, marginBytes: Int64)
    case memoryPressure(warningFraction: Double, criticalFraction: Double)
    /// `hasBattery == false` means a desktop Mac: the factor scores full and the UI can say so.
    case battery(hasBattery: Bool, maxCapacityPercent: Double?, cycles: Int?)
    /// `bytes == nil`: not measured yet, the UI says "Run cleanup check". `fractionOfDisk` is bytes / disk total.
    case reclaimable(bytes: Int64?, fractionOfDisk: Double?)
    /// `overLimit` = items above `HealthScore.startupItemAllowance`.
    case startupItems(total: Int, orphans: Int, overLimit: Int)
}

public struct HealthFactor: Sendable, Identifiable, Codable, Equatable {
    public let id: HealthFactorKind
    public let points: Int
    public let maxPoints: Int
    /// Every factor carries its route; the UI decides whether to show it (for example only when points < max).
    public let fix: FixRoute?
    public let details: HealthFactorDetails
    /// True when the factor scored full because its input is unknown (reclaimable not measured yet).
    public let isUnmeasured: Bool

    public init(id: HealthFactorKind, points: Int, maxPoints: Int, fix: FixRoute?, details: HealthFactorDetails, isUnmeasured: Bool = false) {
        self.id = id
        self.points = points
        self.maxPoints = maxPoints
        self.fix = fix
        self.details = details
        self.isUnmeasured = isUnmeasured
    }

    public var kind: HealthFactorKind { id }
    public var lostPoints: Int { maxPoints - points }
}

public enum HealthBand: String, Sendable, Codable, CaseIterable {
    case good, fair, poor

    /// good ≥ 80, fair 60–79, poor < 60.
    public init(score: Int) {
        self = score >= 80 ? .good : (score >= 60 ? .fair : .poor)
    }
}

public struct HealthReport: Sendable, Codable, Equatable {
    public let score: Int
    public let band: HealthBand
    /// In `HealthFactorKind.allCases` order.
    public let factors: [HealthFactor]

    public init(score: Int, band: HealthBand, factors: [HealthFactor]) {
        self.score = score
        self.band = band
        self.factors = factors
    }

    public func factor(_ kind: HealthFactorKind) -> HealthFactor? { factors.first { $0.id == kind } }

    /// The factor losing the most points (first in ledger order on ties), nil when every factor is full.
    /// The dashboard's contextual primary action fixes this one.
    public var topIssue: HealthFactor? {
        factors.reduce(nil as HealthFactor?) { best, f in
            guard f.lostPoints > 0 else { return best }
            guard let best else { return f }
            return f.lostPoints > best.lostPoints ? f : best
        }
    }

    /// Reclaimable space hasn't been measured; the UI offers "Run cleanup check".
    public var needsCleanupCheck: Bool { factor(.reclaimable)?.isUnmeasured ?? false }
}

/// Health Score, 0–100: disk free 30, memory pressure 20, battery 20, reclaimable 20, startup items 10.
public enum HealthScore {
    public static let diskMaxPoints = 30
    public static let memoryMaxPoints = 20
    public static let batteryMaxPoints = 20
    public static let reclaimableMaxPoints = 20
    public static let startupMaxPoints = 10

    /// Used fraction at which disk free scores full (0.70) and zero (0.97).
    public static let diskFullScoreUsedFraction = 0.70
    public static let diskZeroScoreUsedFraction = 0.97
    /// Battery capacity at which the battery factor scores zero (70 %) and full (95 %).
    public static let batteryZeroScorePercent = 70.0
    public static let batteryRangePercent = 25.0
    /// Reclaimable space equal to this share of the disk scores zero.
    public static let reclaimableZeroScoreFraction = 0.15
    /// Startup items up to this count cost nothing; every 3 above cost 1 point; each orphan costs 2.
    /// (A developer Mac with 20 agents from installed apps is normal; orphans are what matter.)
    public static let startupItemAllowance = 12

    public static func compute(_ inputs: HealthInputs) -> HealthReport {
        let factors = [disk(inputs), memory(inputs), battery(inputs), reclaimable(inputs), startup(inputs)]
        let score = factors.reduce(0) { $0 + $1.points }
        return HealthReport(score: score, band: HealthBand(score: score), factors: factors)
    }

    // MARK: - Factors

    static func disk(_ i: HealthInputs) -> HealthFactor {
        let total = max(i.diskTotal, 0)
        let available = min(max(i.diskAvailable, 0), total)
        let used = total - available
        let usedFraction = total > 0 ? Double(used) / Double(total) : 1
        let ratio = (diskZeroScoreUsedFraction - usedFraction) / (diskZeroScoreUsedFraction - diskFullScoreUsedFraction)
        return HealthFactor(
            id: .diskFree,
            points: points(Double(diskMaxPoints) * clamp(ratio)),
            maxPoints: diskMaxPoints,
            fix: .storageMap,
            details: .diskFree(totalBytes: total, availableBytes: available, usedFraction: usedFraction,
                               marginBytes: LoadLine.marginBytes(total: total, used: used))
        )
    }

    static func memory(_ i: HealthInputs) -> HealthFactor {
        let warning = clamp(i.pressureWarningFraction)
        let critical = clamp(i.pressureCriticalFraction)
        return HealthFactor(
            id: .memoryPressure,
            points: points(Double(memoryMaxPoints) * clamp(1 - 0.5 * warning - 1.0 * critical)),
            maxPoints: memoryMaxPoints,
            fix: .monitor,
            details: .memoryPressure(warningFraction: warning, criticalFraction: critical)
        )
    }

    static func battery(_ i: HealthInputs) -> HealthFactor {
        guard let capacity = i.batteryMaxCapacityPercent else {
            return HealthFactor(id: .battery, points: batteryMaxPoints, maxPoints: batteryMaxPoints, fix: .monitor,
                                details: .battery(hasBattery: false, maxCapacityPercent: nil, cycles: nil))
        }
        return HealthFactor(
            id: .battery,
            points: points(Double(batteryMaxPoints) * clamp((capacity - batteryZeroScorePercent) / batteryRangePercent)),
            maxPoints: batteryMaxPoints,
            fix: .monitor,
            details: .battery(hasBattery: true, maxCapacityPercent: capacity, cycles: i.batteryCycles)
        )
    }

    static func reclaimable(_ i: HealthInputs) -> HealthFactor {
        guard let bytes = i.reclaimableBytes else {
            return HealthFactor(id: .reclaimable, points: reclaimableMaxPoints, maxPoints: reclaimableMaxPoints,
                                fix: .cleanup, details: .reclaimable(bytes: nil, fractionOfDisk: nil), isUnmeasured: true)
        }
        let reclaim = max(bytes, 0)
        let ratio: Double
        let fraction: Double?
        if i.diskTotal > 0 {
            fraction = Double(reclaim) / Double(i.diskTotal)
            ratio = 1 - Double(reclaim) / (reclaimableZeroScoreFraction * Double(i.diskTotal))
        } else {
            fraction = nil
            ratio = reclaim == 0 ? 1 : 0
        }
        return HealthFactor(
            id: .reclaimable,
            points: points(Double(reclaimableMaxPoints) * clamp(ratio)),
            maxPoints: reclaimableMaxPoints,
            fix: .cleanup,
            details: .reclaimable(bytes: reclaim, fractionOfDisk: fraction)
        )
    }

    static func startup(_ i: HealthInputs) -> HealthFactor {
        let total = max(i.startupItems, 0)
        let orphans = max(i.orphanStartupItems, 0)
        let over = max(total - startupItemAllowance, 0)
        return HealthFactor(
            id: .startupItems,
            points: startupPoints(total: total, orphans: orphans),
            maxPoints: startupMaxPoints,
            fix: .loginItems,
            details: .startupItems(total: total, orphans: orphans, overLimit: over)
        )
    }

    /// The startup items factor for these counts; the Login items screen uses it to project the effect of its advice.
    public static func startupPoints(total: Int, orphans: Int) -> Int {
        let over = max(max(total, 0) - startupItemAllowance, 0)
        let raw = startupMaxPoints - 2 * max(orphans, 0) - over / 3
        return min(max(raw, 0), startupMaxPoints)
    }

    // MARK: - Math

    static func clamp(_ x: Double) -> Double {
        guard x.isFinite else { return x > 0 ? 1 : 0 }
        return min(max(x, 0), 1)
    }

    /// Standard rounding (half away from zero).
    static func points(_ x: Double) -> Int { Int(x.rounded(.toNearestOrAwayFromZero)) }
}

/// The 85 % "load line": macOS needs free space for updates and swap, so the dashboard gauge marks
/// 85 % of the volume.
public enum LoadLine {
    public static let fraction = 0.85

    /// The used-bytes position of the line.
    public static func lineBytes(total: Int64) -> Int64 {
        Int64((Double(max(total, 0)) * fraction).rounded(.down))
    }

    /// `0.85 × total − used`: positive = above the line (room left), negative = below it.
    public static func marginBytes(total: Int64, used: Int64) -> Int64 {
        lineBytes(total: total) - used
    }
}
