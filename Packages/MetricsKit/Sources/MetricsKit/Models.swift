import Foundation

/// System-wide CPU load over the interval since the previous sample. All values are fractions 0…1.
public struct CPUSample: Sendable, Equatable {
    /// Busy fraction across all cores (user + nice + system).
    public let total: Double
    /// User-mode fraction (includes niced processes) across all cores.
    public let user: Double
    /// Kernel-mode fraction across all cores.
    public let system: Double
    /// Busy fraction per logical core, in the kernel's processor order.
    public let perCore: [Double]

    public init(total: Double, user: Double, system: Double, perCore: [Double]) {
        self.total = total
        self.user = user
        self.system = system
        self.perCore = perCore
    }
}

/// `kern.memorystatus_vm_pressure_level`: 1 normal (green), 2 warning (yellow), 4 critical (red).
public enum MemoryPressure: Int, Sendable, Codable, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4
}

/// Physical memory, broken down the way Activity Monitor's Memory tab does.
public struct MemorySample: Sendable, Equatable {
    /// Installed RAM (`hw.memsize`).
    public let totalBytes: UInt64
    /// "Memory Used" = app + wired + compressed.
    public let usedBytes: UInt64
    /// "App Memory" = anonymous (internal) pages minus purgeable pages.
    public let appBytes: UInt64
    /// "Wired Memory".
    public let wiredBytes: UInt64
    /// "Compressed" (pages occupied by the compressor).
    public let compressedBytes: UInt64
    /// "Cached Files" = file-backed (external) pages plus purgeable pages.
    public let cachedBytes: UInt64
    /// "Swap Used" (`vm.swapusage`).
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressure

    public init(
        totalBytes: UInt64, usedBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64,
        compressedBytes: UInt64, cachedBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressure
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }
}

/// Startup volume capacity.
public struct DiskSample: Sendable, Equatable {
    public let volumeName: String
    public let totalBytes: Int64
    /// Capacity available for important usage (what Finder shows; purgeable space counts as available).
    public let availableBytes: Int64
    /// `totalBytes - availableBytes`.
    public let usedBytes: Int64

    public init(volumeName: String, totalBytes: Int64, availableBytes: Int64) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.usedBytes = max(0, totalBytes - availableBytes)
    }
}

/// Network throughput summed over the non-loopback interfaces that are up.
public struct NetworkSample: Sendable, Equatable {
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double
    /// Bytes received since the sampler first saw each interface, plus that interface's counter at that time.
    /// Interface counters are 32-bit, so this is a "since the sampler started" figure seeded with the
    /// (possibly wrapped) kernel counters, not an exact since-boot total.
    public let totalIn: UInt64
    public let totalOut: UInt64

    public init(bytesInPerSecond: Double, bytesOutPerSecond: Double, totalIn: UInt64, totalOut: UInt64) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
        self.totalIn = totalIn
        self.totalOut = totalOut
    }
}

/// Internal battery state and health.
public struct BatteryInfo: Sendable, Equatable {
    /// False on Macs without an internal battery; every other field is then nil/false.
    public var isPresent: Bool
    /// State of charge 0…100.
    public var chargePercent: Int?
    public var isCharging: Bool
    /// External power connected (charging or not).
    public var isPluggedIn: Bool
    public var cycleCount: Int?
    /// Design capacity in mAh.
    public var designCapacity: Int?
    /// Current full-charge capacity in mAh (`NominalChargeCapacity`, falling back to `AppleRawMaxCapacity`).
    public var maxCapacity: Int?
    /// Maximum capacity relative to design, 0…100. Estimated from the registry; replace it with System
    /// Information's exact figure via `BatteryInfo.applying(_:)` when available (see `BatteryReader`).
    public var maxCapacityPercent: Double?
    /// "Normal" or "Service Recommended" (other raw system values pass through unchanged).
    public var condition: String?
    /// Battery (gas gauge) temperature in °C.
    public var temperatureCelsius: Double?
    /// Connected adapter's rating in watts, when plugged in.
    public var adapterWatts: Int?
    /// Minutes to empty when discharging, or to full when charging; nil when unknown or not applicable.
    public var timeRemainingMinutes: Int?

    public init(
        isPresent: Bool, chargePercent: Int? = nil, isCharging: Bool = false, isPluggedIn: Bool = false,
        cycleCount: Int? = nil, designCapacity: Int? = nil, maxCapacity: Int? = nil,
        maxCapacityPercent: Double? = nil, condition: String? = nil, temperatureCelsius: Double? = nil,
        adapterWatts: Int? = nil, timeRemainingMinutes: Int? = nil
    ) {
        self.isPresent = isPresent
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.maxCapacityPercent = maxCapacityPercent
        self.condition = condition
        self.temperatureCelsius = temperatureCelsius
        self.adapterWatts = adapterWatts
        self.timeRemainingMinutes = timeRemainingMinutes
    }

    /// A Mac without an internal battery.
    public static let absent = BatteryInfo(isPresent: false)
}

/// One running process.
public struct ProcessSample: Sendable, Identifiable, Equatable {
    /// The process id.
    public let id: Int32
    public let name: String
    /// Owner's short user name (or the numeric uid as text when it has no passwd entry).
    public let userName: String
    public let uid: UInt32
    /// CPU over the last interval; 100 = one full core. 0 on the first sample that sees the process.
    public let cpuPercent: Double
    /// Physical footprint (Activity Monitor's "Memory" column).
    public let memoryBytes: UInt64
    /// Bundle identifier of the innermost `.app` containing the executable, if any.
    public let bundleIdentifier: String?
    public let isOwnedByCurrentUser: Bool
    /// Executable path, when readable.
    public let path: String?
    /// True when CPU and memory could not be read (typically another user's or a root process);
    /// `cpuPercent` and `memoryBytes` are then 0.
    public let isRestricted: Bool

    public init(
        id: Int32, name: String, userName: String, uid: UInt32, cpuPercent: Double, memoryBytes: UInt64,
        bundleIdentifier: String?, isOwnedByCurrentUser: Bool, path: String? = nil, isRestricted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.userName = userName
        self.uid = uid
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.bundleIdentifier = bundleIdentifier
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
        self.path = path
        self.isRestricted = isRestricted
    }
}

/// Everything one `MetricsSampler.sample` call measured. Readings that failed or need a previous sample are nil.
public struct MetricsSnapshot: Sendable {
    public let date: Date
    /// nil on the sampler's first call (no tick delta yet).
    public let cpu: CPUSample?
    public let memory: MemorySample?
    public let disk: DiskSample?
    /// nil on the sampler's first call (no byte-counter delta yet).
    public let network: NetworkSample?
    /// `BatteryInfo.absent` on desktops; nil only if IOKit could not be queried.
    public let battery: BatteryInfo?
    /// SoC die temperature in °C; nil when not requested or unavailable (the app may fall back to the battery's).
    public let temperatureCelsius: Double?
    /// Empty unless requested. Sorted by CPU, then memory, descending.
    public let processes: [ProcessSample]

    public init(
        date: Date, cpu: CPUSample?, memory: MemorySample?, disk: DiskSample?, network: NetworkSample?,
        battery: BatteryInfo?, temperatureCelsius: Double?, processes: [ProcessSample]
    ) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.battery = battery
        self.temperatureCelsius = temperatureCelsius
        self.processes = processes
    }
}
