import Darwin
import Foundation
import IOKit

/// Static facts about this Mac. Cheap to compute; call once and keep it.
public struct SystemInfo: Sendable, Equatable {
    /// Marketing name, e.g. "MacBook Pro (16-inch, M5 Pro)"; falls back to `modelIdentifier`.
    public let modelName: String
    /// e.g. "Mac17,8" (`hw.model`).
    public let modelIdentifier: String
    /// e.g. "Apple M5 Pro" (`machdep.cpu.brand_string`).
    public let chip: String
    /// e.g. "27.0" or "27.0.1".
    public let macOSVersion: String
    /// e.g. "26A123" (`kern.osversion`).
    public let macOSBuild: String
    /// Logical cores.
    public let coreCount: Int
    public let memoryBytes: UInt64
    public let bootDate: Date

    public init(
        modelName: String, modelIdentifier: String, chip: String, macOSVersion: String, macOSBuild: String = "",
        coreCount: Int, memoryBytes: UInt64, bootDate: Date
    ) {
        self.modelName = modelName
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.coreCount = coreCount
        self.memoryBytes = memoryBytes
        self.bootDate = bootDate
    }

    /// Time since boot as of `now`.
    public func uptime(now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(bootDate)) }

    public static func current() -> SystemInfo {
        let identifier = Sysctl.string("hw.model") ?? ""
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var bootDate = Date(timeIntervalSince1970: 0)
        if let boot = Sysctl.value("kern.boottime", as: timeval.self, initial: timeval()) {
            bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        }
        return SystemInfo(
            modelName: productName() ?? identifier,
            modelIdentifier: identifier,
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "",
            macOSVersion: versionString,
            macOSBuild: Sysctl.string("kern.osversion") ?? "",
            coreCount: ProcessInfo.processInfo.processorCount,
            memoryBytes: Sysctl.uint64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory,
            bootDate: bootDate
        )
    }

    /// Apple silicon publishes the marketing name as `product-name` on `IODeviceTree:/product`.
    static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let bytes = data.prefix { $0 != 0 }
        let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
