import Foundation

/// User-set alert thresholds. A nil value turns that alert off.
public struct AlertThresholds: Sendable, Codable, Equatable {
    public var diskFreeBelowBytes: Int64?
    public var memoryRedMinutes: Int?
    public var temperatureAboveCelsius: Double?
    public var batteryCapacityBelowPercent: Double?

    public init(diskFreeBelowBytes: Int64?, memoryRedMinutes: Int?, temperatureAboveCelsius: Double?, batteryCapacityBelowPercent: Double?) {
        self.diskFreeBelowBytes = diskFreeBelowBytes
        self.memoryRedMinutes = memoryRedMinutes
        self.temperatureAboveCelsius = temperatureAboveCelsius
        self.batteryCapacityBelowPercent = batteryCapacityBelowPercent
    }

    /// Disk below 10 GB, memory red for 5 minutes, temperature above 95 °C, battery capacity below 80 %.
    public static let defaults = AlertThresholds(
        diskFreeBelowBytes: 10_000_000_000,
        memoryRedMinutes: 5,
        temperatureAboveCelsius: 95,
        batteryCapacityBelowPercent: 80
    )
}

/// One reading. Nil fields are "not measured this time" and leave that alert's state unchanged.
public struct AlertSample: Sendable, Equatable {
    public var date: Date
    public var diskAvailable: Int64?
    /// `MetricsKit.MemoryPressure` raw value: 1 normal, 2 warning, 4 critical.
    public var pressure: Int?
    public var temperatureCelsius: Double?
    public var batteryMaxCapacityPercent: Double?

    public init(date: Date, diskAvailable: Int64? = nil, pressure: Int? = nil, temperatureCelsius: Double? = nil, batteryMaxCapacityPercent: Double? = nil) {
        self.date = date
        self.diskAvailable = diskAvailable
        self.pressure = pressure
        self.temperatureCelsius = temperatureCelsius
        self.batteryMaxCapacityPercent = batteryMaxCapacityPercent
    }
}

public enum AlertKind: String, Sendable, Codable, CaseIterable {
    case diskLow, memoryRed, temperatureHigh, batteryWorn
}

/// What to notify. `value` and `threshold` are in the alert's unit: bytes, minutes at critical, °C, percent.
public struct AlertEvent: Sendable, Equatable {
    public let kind: AlertKind
    public let value: Double
    public let threshold: Double

    public init(kind: AlertKind, value: Double, threshold: Double) {
        self.kind = kind
        self.value = value
        self.threshold = threshold
    }
}

/// Decides when threshold alerts fire. Pure and deterministic: time comes only from sample dates.
///
/// - An alert fires once when its condition starts holding (a crossing), then stays quiet while it holds.
/// - It re-arms only after the value recovers past a hysteresis band: disk free ≥ threshold + 10 %,
///   temperature ≤ threshold − 5 °C, battery capacity ≥ threshold + 1 point, memory not critical for 2 minutes.
/// - Each kind has a 6-hour cool-down after it fires, even when re-armed. A crossing that happens during
///   the cool-down is not dropped: if the condition still holds when the cool-down ends, it fires then.
/// - Memory red needs pressure == critical in every sample for at least `memoryRedMinutes`. A gap of more
///   than `maxSampleGap` between samples (sleep, app not running) restarts that count.
///
/// The app persists the engine (Codable) so cool-downs and armed state survive relaunches.
public struct AlertEngine: Sendable, Codable, Equatable {
    public static let coolDown: TimeInterval = 6 * 3600
    public static let memoryRecovery: TimeInterval = 2 * 60
    public static let maxSampleGap: TimeInterval = 5 * 60
    public static let diskRecoveryFactor = 1.10
    public static let temperatureRecoveryCelsius = 5.0
    public static let batteryRecoveryPoints = 1.0
    static let criticalPressure = 4

    public private(set) var thresholds: AlertThresholds
    private var states: [AlertKind: KindState]
    private var memory: MemoryState

    struct KindState: Sendable, Codable, Equatable {
        var armed = true
        var lastFired: Date?
    }

    struct MemoryState: Sendable, Codable, Equatable {
        var criticalSince: Date?
        var notCriticalSince: Date?
        var lastSample: Date?
    }

    public init(thresholds: AlertThresholds = .defaults) {
        self.thresholds = thresholds
        self.states = Dictionary(uniqueKeysWithValues: AlertKind.allCases.map { ($0, KindState()) })
        self.memory = MemoryState()
    }

    /// Replaces the thresholds. Kinds whose threshold changed start fresh (armed, no cool-down), so a new
    /// setting that is already crossed notifies on the next sample.
    public mutating func update(thresholds new: AlertThresholds) {
        let old = thresholds
        thresholds = new
        if old.diskFreeBelowBytes != new.diskFreeBelowBytes { states[.diskLow] = KindState() }
        if old.temperatureAboveCelsius != new.temperatureAboveCelsius { states[.temperatureHigh] = KindState() }
        if old.batteryCapacityBelowPercent != new.batteryCapacityBelowPercent { states[.batteryWorn] = KindState() }
        if old.memoryRedMinutes != new.memoryRedMinutes { states[.memoryRed] = KindState() }
    }

    /// Whether the kind is armed (would fire on its next crossing, cool-down permitting).
    public func isArmed(_ kind: AlertKind) -> Bool { states[kind]?.armed ?? true }
    public func lastFired(_ kind: AlertKind) -> Date? { states[kind]?.lastFired }

    /// Feed samples in date order. Returns the alerts to notify, in `AlertKind.allCases` order.
    public mutating func evaluate(_ sample: AlertSample) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let now = sample.date

        if let threshold = thresholds.diskFreeBelowBytes, let available = sample.diskAvailable {
            let t = Double(threshold), v = Double(available)
            if let e = step(.diskLow, now: now, crossed: v < t, recovered: v >= t * Self.diskRecoveryFactor, value: v, threshold: t) {
                events.append(e)
            }
        }

        if let pressure = sample.pressure {
            let critical = pressure == Self.criticalPressure
            if let last = memory.lastSample, now.timeIntervalSince(last) > Self.maxSampleGap {
                memory.criticalSince = nil
                memory.notCriticalSince = nil
            }
            if critical {
                if memory.criticalSince == nil { memory.criticalSince = now }
                memory.notCriticalSince = nil
            } else {
                if memory.notCriticalSince == nil { memory.notCriticalSince = now }
                memory.criticalSince = nil
            }
            memory.lastSample = now
            if let minutes = thresholds.memoryRedMinutes {
                let required = TimeInterval(max(minutes, 0)) * 60
                let criticalFor = memory.criticalSince.map { now.timeIntervalSince($0) }
                let calmFor = memory.notCriticalSince.map { now.timeIntervalSince($0) }
                if let e = step(.memoryRed, now: now,
                                crossed: (criticalFor ?? -1) >= required,
                                recovered: (calmFor ?? -1) >= Self.memoryRecovery,
                                value: (criticalFor ?? 0) / 60, threshold: Double(minutes)) {
                    events.append(e)
                }
            }
        }

        if let threshold = thresholds.temperatureAboveCelsius, let temp = sample.temperatureCelsius {
            if let e = step(.temperatureHigh, now: now, crossed: temp > threshold,
                            recovered: temp <= threshold - Self.temperatureRecoveryCelsius, value: temp, threshold: threshold) {
                events.append(e)
            }
        }

        if let threshold = thresholds.batteryCapacityBelowPercent, let capacity = sample.batteryMaxCapacityPercent {
            if let e = step(.batteryWorn, now: now, crossed: capacity < threshold,
                            recovered: capacity >= threshold + Self.batteryRecoveryPoints, value: capacity, threshold: threshold) {
                events.append(e)
            }
        }
        return events
    }

    private mutating func step(_ kind: AlertKind, now: Date, crossed: Bool, recovered: Bool, value: Double, threshold: Double) -> AlertEvent? {
        var state = states[kind] ?? KindState()
        defer { states[kind] = state }
        if !state.armed {
            if recovered { state.armed = true }
            return nil
        }
        guard crossed else { return nil }
        if let last = state.lastFired, now.timeIntervalSince(last) < Self.coolDown { return nil }
        state.armed = false
        state.lastFired = now
        return AlertEvent(kind: kind, value: value, threshold: threshold)
    }
}
