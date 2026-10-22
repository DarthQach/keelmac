import Foundation
import IOKit
import IOKit.ps

/// Health figures from System Information (`system_profiler SPPowerDataType -json`).
public struct BatterySystemReport: Sendable, Equatable {
    public var cycleCount: Int?
    /// System Information's "Maximum Capacity", 0…100.
    public var maxCapacityPercent: Double?
    /// Normalized like `BatteryInfo.condition`.
    public var condition: String?

    public init(cycleCount: Int?, maxCapacityPercent: Double?, condition: String?) {
        self.cycleCount = cycleCount
        self.maxCapacityPercent = maxCapacityPercent
        self.condition = condition
    }
}

extension BatteryInfo {
    /// Replaces the registry estimates with System Information's figures where it has them.
    public func applying(_ report: BatterySystemReport) -> BatteryInfo {
        guard isPresent else { return self }
        var copy = self
        if let value = report.cycleCount { copy.cycleCount = value }
        if let value = report.maxCapacityPercent { copy.maxCapacityPercent = value }
        if let value = report.condition { copy.condition = value }
        return copy
    }
}

/// Internal battery via the `AppleSmartBattery` IORegistry service plus IOPowerSources.
///
/// Since macOS 26 most gauge values (`DesignCapacity`, `NominalChargeCapacity`, `AppleRawMaxCapacity`,
/// `Temperature`) live in the `BatteryData` dictionary of the `AppleSmartBatteryPack` child rather than on the
/// service itself; `read()` collects both into the same shape `ioreg -l -a -r -n AppleSmartBattery` prints
/// (root properties plus `IORegistryEntryChildren`), and `parse` looks a key up at every level.
///
/// The exact "Maximum Capacity" percentage System Information shows comes from an entitlement-gated power
/// source API (`IOPSCopyPowerSourcesByTypePrecise` returns `kIOReturnNotPrivileged` to normal apps), so the
/// registry figure is an estimate: `NominalChargeCapacity / DesignCapacity`. For an exact match, run
/// `systemProfilerExecutable` with `systemProfilerArguments` (through SafetyKit's `CommandRunning`, about 80 ms;
/// health changes slowly, so once per launch or hour is plenty), parse it with `parseSystemProfiler(json:)` and
/// apply it with `BatteryInfo.applying(_:)`.
public enum BatteryReader {
    public static let systemProfilerExecutable = "/usr/sbin/system_profiler"
    public static let systemProfilerArguments = ["SPPowerDataType", "-json"]

    /// Current battery state. `BatteryInfo.absent` on Macs without a battery; nil only if IOKit fails entirely.
    public static func read() -> BatteryInfo? {
        let powerSource = internalPowerSourceDescription()
        guard let registry = registryDictionary() else {
            return powerSource == nil ? .absent : parse(registry: [:], powerSource: powerSource)
        }
        return parse(registry: registry, powerSource: powerSource)
    }

    // MARK: - Parsing

    /// Builds a `BatteryInfo` from an `AppleSmartBattery` registry dictionary (as `ioreg -l -a` prints it,
    /// optionally with `IORegistryEntryChildren`) and the internal battery's IOPowerSources description.
    public static func parse(registry: [String: Any], powerSource: [String: Any]?) -> BatteryInfo {
        let lookup = RegistryLookup(registry)
        let source = powerSource ?? [:]
        let sourceIsBattery = (source[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            && (number(source[kIOPSIsPresentKey])?.boolValue ?? true)
        if registry.isEmpty && !sourceIsBattery { return .absent }
        if lookup.bool("BatteryInstalled") == false { return .absent }

        // Charge
        var chargePercent: Int?
        if let current = number(source[kIOPSCurrentCapacityKey])?.doubleValue,
           let max = number(source[kIOPSMaxCapacityKey])?.doubleValue, max > 0 {
            chargePercent = percent(current, of: max)
        } else if let current = lookup.double("CurrentCapacity"), let max = lookup.double("MaxCapacity"), max > 0 {
            // On Apple silicon both are already percentages; on Intel both are mAh. The ratio works for either.
            chargePercent = percent(current, of: max)
        }

        let isCharging = lookup.bool("IsCharging") ?? number(source[kIOPSIsChargingKey])?.boolValue ?? false
        let isPluggedIn = lookup.bool("ExternalConnected")
            ?? ((source[kIOPSPowerSourceStateKey] as? String).map { $0 == kIOPSACPowerValue } ?? false)

        // Health
        let cycleCount = lookup.int("CycleCount")
        let design = lookup.int("DesignCapacity").flatMap { $0 > 0 ? $0 : nil }
        let full = (lookup.int("NominalChargeCapacity") ?? lookup.int("AppleRawMaxCapacity")).flatMap { $0 > 0 ? $0 : nil }
        var maxPercent: Double?
        if let health = source["BatteryHealth"] as? [String: Any],
           let exact = number(health["Maximum Capacity Percent"])?.doubleValue {
            maxPercent = exact
        } else if let design, let full {
            maxPercent = min(100, Double(full) / Double(design) * 100)
        }

        var condition: String?
        if let failure = lookup.int("PermanentFailureStatus"), failure != 0 {
            condition = "Service Recommended"
        } else if let raw = source["BatteryHealthCondition"] as? String, !raw.isEmpty {
            condition = normalizeCondition(raw)
        } else if let raw = source["BatteryHealth"] as? String, !raw.isEmpty {
            condition = normalizeCondition(raw)
        } else if cycleCount != nil || design != nil {
            condition = "Normal"
        }

        // Temperature in hundredths of a degree Celsius.
        var temperature: Double?
        if let raw = lookup.double("Temperature") ?? lookup.double("VirtualTemperature") {
            let celsius = raw / 100
            if (-40...100).contains(celsius) { temperature = celsius }
        }

        var adapterWatts: Int?
        if isPluggedIn {
            let details = lookup.value("AdapterDetails") as? [String: Any]
                ?? (lookup.value("AppleRawAdapterDetails") as? [[String: Any]])?.first
            if let watts = number(details?["Watts"])?.intValue, watts > 0 { adapterWatts = watts }
        }

        var minutes: Int?
        if isCharging {
            minutes = validMinutes(number(source[kIOPSTimeToFullChargeKey])?.intValue)
                ?? validMinutes(lookup.int("AvgTimeToFull"))
        } else if !isPluggedIn {
            minutes = validMinutes(number(source[kIOPSTimeToEmptyKey])?.intValue)
                ?? validMinutes(lookup.int("TimeRemaining"))
                ?? validMinutes(lookup.int("AvgTimeToEmpty"))
        }

        return BatteryInfo(
            isPresent: true,
            chargePercent: chargePercent,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            cycleCount: cycleCount,
            designCapacity: design,
            maxCapacity: full,
            maxCapacityPercent: maxPercent,
            condition: condition,
            temperatureCelsius: temperature,
            adapterWatts: adapterWatts,
            timeRemainingMinutes: minutes
        )
    }

    /// Parses `system_profiler SPPowerDataType -json`. Returns nil when there is no battery section.
    public static func parseSystemProfiler(json: Data) -> BatterySystemReport? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sections = root["SPPowerDataType"] as? [[String: Any]],
              let battery = sections.first(where: { ($0["_name"] as? String) == "spbattery_information" }),
              let health = battery["sppower_battery_health_info"] as? [String: Any] else { return nil }
        let cycles = number(health["sppower_battery_cycle_count"])?.intValue
        var maxPercent: Double?
        if let text = health["sppower_battery_health_maximum_capacity"] as? String {
            maxPercent = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        } else if let value = number(health["sppower_battery_health_maximum_capacity"]) {
            maxPercent = value.doubleValue
        }
        let condition = (health["sppower_battery_health"] as? String).map(normalizeCondition)
        if cycles == nil && maxPercent == nil && condition == nil { return nil }
        return BatterySystemReport(cycleCount: cycles, maxCapacityPercent: maxPercent, condition: condition)
    }

    /// Maps the system's health words onto "Normal" / "Service Recommended"; unknown values pass through.
    static func normalizeCondition(_ raw: String) -> String {
        switch raw.lowercased() {
        case "good", "normal": return "Normal"
        case "fair", "poor", "check battery", "service battery", "service recommended", "replace soon",
             "replace now", "permanent battery failure", "permanent failure":
            return "Service Recommended"
        default: return raw
        }
    }

    private static func percent(_ value: Double, of total: Double) -> Int {
        Int(min(100, max(0, (value / total * 100).rounded())))
    }

    private static func validMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 65_535 else { return nil }
        return value
    }

    static func number(_ value: Any?) -> NSNumber? { value as? NSNumber }

    // MARK: - IOKit

    static func registryDictionary() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              var properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        if IORegistryEntryGetChildIterator(service, "IOService", &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var children: [[String: Any]] = []
            while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
                defer { IOObjectRelease(child) }
                let className = objectClass(child)
                guard className == "AppleSmartBatteryPack",
                      let data = IORegistryEntryCreateCFProperty(child, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [String: Any] else { continue }
                children.append(["IOObjectClass": className, "BatteryData": data])
            }
            if !children.isEmpty { properties["IORegistryEntryChildren"] = children }
        }
        return properties
    }

    private static func objectClass(_ object: io_object_t) -> String {
        guard let name = IOObjectCopyClass(object)?.takeRetainedValue() else { return "" }
        return name as String
    }

    static func internalPowerSourceDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType { return description }
        }
        return nil
    }
}

/// Looks a key up on the service, then in its `BatteryData`, then in each pack child's `BatteryData`.
struct RegistryLookup {
    private let levels: [[String: Any]]

    init(_ registry: [String: Any]) {
        var levels: [[String: Any]] = [registry]
        if let data = registry["BatteryData"] as? [String: Any] { levels.append(data) }
        for child in registry["IORegistryEntryChildren"] as? [[String: Any]] ?? [] {
            if let data = child["BatteryData"] as? [String: Any] { levels.append(data) }
        }
        self.levels = levels
    }

    func value(_ key: String) -> Any? {
        for level in levels { if let value = level[key] { return value } }
        return nil
    }

    func int(_ key: String) -> Int? { (value(key) as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }
    func bool(_ key: String) -> Bool? { (value(key) as? NSNumber)?.boolValue }
}
