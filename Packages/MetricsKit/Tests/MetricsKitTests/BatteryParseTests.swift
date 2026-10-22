import Foundation
import Testing
@testable import MetricsKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func dictionaryFixture(_ name: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
}

@Suite("Battery parsing")
struct BatteryParseTests {
    /// Real (trimmed) `ioreg -l -a -r -n AppleSmartBattery` from a MacBook Pro M5 Pro on macOS 27, on AC, full.
    @Test func laptopFixture() throws {
        let registry = try dictionaryFixture("battery-macbookpro-m5pro-registry")
        let source = try dictionaryFixture("battery-macbookpro-m5pro-powersource")
        let info = BatteryReader.parse(registry: registry, powerSource: source)
        #expect(info.isPresent)
        #expect(info.chargePercent == 100)
        #expect(info.isPluggedIn)
        #expect(!info.isCharging)
        #expect(info.cycleCount == 70)                  // System Information: Cycle Count 70
        #expect(info.designCapacity == 8_579)
        #expect(info.maxCapacity == 8_374)              // NominalChargeCapacity (in the pack child's BatteryData)
        let percent = try #require(info.maxCapacityPercent)
        #expect(abs(percent - 97.61) < 0.01)            // estimate; System Information says 99 % (see below)
        #expect(info.condition == "Normal")
        #expect(info.temperatureCelsius == 29.79)
        #expect(info.adapterWatts == 140)
        #expect(info.timeRemainingMinutes == nil)       // on AC and full
    }

    @Test func systemProfilerReportGivesExactFigures() throws {
        let report = try #require(BatteryReader.parseSystemProfiler(json: fixture("battery-macbookpro-m5pro-system-profiler")))
        #expect(report == BatterySystemReport(cycleCount: 70, maxCapacityPercent: 99, condition: "Normal"))
        let registry = try dictionaryFixture("battery-macbookpro-m5pro-registry")
        let merged = BatteryReader.parse(registry: registry, powerSource: nil).applying(report)
        #expect(merged.maxCapacityPercent == 99)
        #expect(merged.cycleCount == 70)
        #expect(BatteryInfo.absent.applying(report) == .absent)
    }

    @Test func desktopWithoutBattery() throws {
        let registry = try dictionaryFixture("battery-desktop-registry")
        #expect(BatteryReader.parse(registry: registry, powerSource: nil) == .absent)
        // A desktop on a UPS reports a power source of a different type: still no internal battery.
        let ups: [String: Any] = ["Type": "UPS", "Is Present": true, "Current Capacity": 80, "Max Capacity": 100]
        #expect(BatteryReader.parse(registry: [:], powerSource: ups) == .absent)
        #expect(BatteryReader.parse(registry: ["BatteryInstalled": false], powerSource: nil).isPresent == false)
        #expect(BatteryReader.parseSystemProfiler(json: Data(#"{"SPPowerDataType":[{"_name":"sppower_information"}]}"#.utf8)) == nil)
    }

    /// Older macOS (≤ 15) and Intel put everything on the service itself.
    @Test func legacyFlatRegistryDischarging() throws {
        let registry: [String: Any] = [
            "BatteryInstalled": true, "CycleCount": 812, "DesignCapacity": 6_669, "AppleRawMaxCapacity": 5_002,
            "CurrentCapacity": 2_501, "MaxCapacity": 5_002, "Temperature": 3_150, "IsCharging": false,
            "ExternalConnected": false, "TimeRemaining": 187, "PermanentFailureStatus": 0,
        ]
        let info = BatteryReader.parse(registry: registry, powerSource: nil)
        #expect(info.chargePercent == 50)
        #expect(info.maxCapacity == 5_002)
        #expect(abs(try #require(info.maxCapacityPercent) - 75.0) < 0.01)
        #expect(info.temperatureCelsius == 31.5)
        #expect(info.timeRemainingMinutes == 187)
        #expect(info.adapterWatts == nil)
        #expect(info.condition == "Normal")
    }

    @Test func chargingUsesTimeToFullAndConditionMapping() {
        let registry: [String: Any] = [
            "CycleCount": 5, "IsCharging": true, "ExternalConnected": true, "AvgTimeToFull": 42,
            "AdapterDetails": ["Watts": 96], "PermanentFailureStatus": 1,
        ]
        let source: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 64, "Max Capacity": 100, "Time to Full Charge": -1]
        let info = BatteryReader.parse(registry: registry, powerSource: source)
        #expect(info.chargePercent == 64)
        #expect(info.timeRemainingMinutes == 42)        // IOPS says -1 (calculating) → registry average
        #expect(info.adapterWatts == 96)
        #expect(info.condition == "Service Recommended")
        #expect(BatteryReader.normalizeCondition("Good") == "Normal")
        #expect(BatteryReader.normalizeCondition("Check Battery") == "Service Recommended")
        #expect(BatteryReader.normalizeCondition("Something New") == "Something New")
    }
}
