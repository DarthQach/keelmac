import Foundation

/// Apple-silicon SoC temperature from the IOHID event system's temperature sensors (the approach the
/// open-source Stats app uses). The IOHID event-system functions are private, so they are resolved with
/// `dlsym` at run time; if anything is missing the reader returns nil and never crashes.
public enum TemperatureReader {
    /// Hottest CPU/SoC die sensor in °C, or nil when no such sensor is readable (e.g. Intel Macs).
    /// The first call discovers sensors (~100 ms); later calls cost roughly 30 ms wall time, < 1 ms CPU.
    public static func socCelsius() -> Double? {
        HIDTemperatureSensors.shared.socCelsius()
    }

    /// Every readable temperature sensor as (product name, °C), for diagnostics.
    public static func allSensors() -> [(name: String, celsius: Double)] {
        HIDTemperatureSensors.shared.allSensors()
    }

    /// Whether a sensor name denotes a CPU/SoC die sensor worth including in `socCelsius()`.
    public static func isSoCSensor(_ name: String) -> Bool {
        // Die sensors ("PMU tdie*" on M1–M5, "pACC"/"eACC" cluster sensors and "SOC MTR Temp" on some models).
        // "PMU tdev*", "PMU tcal", NAND and gas-gauge sensors are not die temperatures and are excluded.
        let prefixes = ["PMU tdie", "PMU2 tdie", "pACC", "eACC", "SOC MTR Temp"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// Representative SoC value: the max of plausible readings (sensors report garbage like -9201 when idle/off).
    public static func representative(_ readings: [Double]) -> Double? {
        readings.filter { (1...150).contains($0) }.max()
    }
}

/// Lock-guarded cache of the IOHID client and the matching sensor services.
final class HIDTemperatureSensors: @unchecked Sendable {
    static let shared = HIDTemperatureSensors()

    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (AnyObject, Int32) -> Double

    private struct Functions {
        let createClient: CreateClient
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyProperty: CopyProperty
        let copyEvent: CopyEvent
        let getFloatValue: GetFloatValue
    }

    private struct Sensor {
        let name: String
        let service: AnyObject
    }

    private static let temperatureEventType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureLevelField: Int32 = 15 << 16      // kIOHIDEventFieldTemperatureLevel
    private static let rediscoverInterval: TimeInterval = 600

    private let lock = NSLock()
    private var functions: Functions?
    private var resolved = false
    private var client: AnyObject?
    private var sensors: [Sensor] = []
    private var discoveredAt: Date?

    func socCelsius() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let functions = loadFunctions() else { return nil }
        discoverIfNeeded(functions)
        let readings = sensors.lazy.filter { TemperatureReader.isSoCSensor($0.name) }.compactMap { self.read($0, functions) }
        return TemperatureReader.representative(Array(readings))
    }

    func allSensors() -> [(name: String, celsius: Double)] {
        lock.lock()
        defer { lock.unlock() }
        guard let functions = loadFunctions() else { return [] }
        discoverIfNeeded(functions)
        return sensors.compactMap { sensor in read(sensor, functions).map { (sensor.name, $0) } }
    }

    private func read(_ sensor: Sensor, _ functions: Functions) -> Double? {
        guard let event = functions.copyEvent(sensor.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else {
            return nil
        }
        let value = functions.getFloatValue(event, Self.temperatureLevelField)
        return value.isFinite ? value : nil
    }

    private func discoverIfNeeded(_ functions: Functions) {
        if let discoveredAt, Date().timeIntervalSince(discoveredAt) < Self.rediscoverInterval, !sensors.isEmpty { return }
        discoveredAt = Date()
        if client == nil {
            guard let created = functions.createClient(kCFAllocatorDefault)?.takeRetainedValue() else { return }
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
            _ = functions.setMatching(created, matching)
            client = created
        }
        guard let client, let services = functions.copyServices(client)?.takeRetainedValue() as [AnyObject]? else {
            sensors = []
            return
        }
        sensors = services.compactMap { service in
            guard let name = functions.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else {
                return nil
            }
            return Sensor(name: name, service: service)
        }
    }

    private func loadFunctions() -> Functions? {
        if resolved { return functions }
        resolved = true
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let createClient = symbol("IOHIDEventSystemClientCreate", CreateClient.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloatValue = symbol("IOHIDEventGetFloatValue", GetFloatValue.self) else { return nil }
        functions = Functions(
            createClient: createClient, setMatching: setMatching, copyServices: copyServices,
            copyProperty: copyProperty, copyEvent: copyEvent, getFloatValue: getFloatValue
        )
        return functions
    }
}
