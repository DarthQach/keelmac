import Foundation

/// Owns the stateful readers (CPU ticks, network counters, per-process CPU times) and produces snapshots.
///
/// Rates are deltas since the previous `sample` call, so the **first call returns nil `cpu` and `network`**,
/// and every process's `cpuPercent` is 0 on the first call that includes processes. Call it on a steady
/// interval (e.g. every 2 s).
///
/// Cost on a MacBook Pro M5 Pro (optimized build, ~3,400 processes): CPU + memory + network + battery ≈ 0.4 ms;
/// disk ≈ 8 ms CPU (the "important usage" capacity query is expensive), so it is re-read at most every
/// `diskInterval` seconds; processes ≈ 15 ms CPU; temperature ≈ 30–40 ms wall but < 2 ms CPU (IPC wait).
public actor MetricsSampler {
    private let cpuReader = CPUReader()
    private var network = NetworkAccumulator()
    private let processReader = ProcessReader()
    private let diskInterval: TimeInterval
    private var disk: (sample: DiskSample?, at: TimeInterval)?

    /// - Parameter diskInterval: minimum seconds between startup-volume reads (0 = every sample).
    public init(diskInterval: TimeInterval = 10) {
        self.diskInterval = diskInterval
    }

    public func sample(includeProcesses: Bool, includeTemperature: Bool) -> MetricsSnapshot {
        let now = NetworkReader.monotonicSeconds()
        let cpu = cpuReader.read()
        let memory = MemoryReader.read()
        let networkSample = network.update(NetworkReader.counters(), at: now)

        if let cached = disk, now - cached.at < diskInterval {
            // Startup-volume reading is still fresh.
        } else {
            disk = (DiskReader.read(path: "/"), now)
        }

        return MetricsSnapshot(
            date: Date(),
            cpu: cpu,
            memory: memory,
            disk: disk?.sample,
            network: networkSample,
            battery: BatteryReader.read(),
            temperatureCelsius: includeTemperature ? TemperatureReader.socCelsius() : nil,
            processes: includeProcesses ? processReader.read() : []
        )
    }

    /// Forces the next `sample` to re-read the startup volume (e.g. right after a cleanup freed space).
    public func refreshDiskOnNextSample() {
        disk = nil
    }
}
