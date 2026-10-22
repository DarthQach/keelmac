import Foundation

/// Owns the stateful readers (CPU ticks, network counters, per-process CPU times) and produces snapshots.
///
/// Rates are deltas since the previous `sample` call, so the **first call returns nil `cpu` and `network`**,
/// and every process's `cpuPercent` is 0 on the first call that includes processes. Call it on a steady
/// interval (e.g. every 2 s). Disk and battery change slowly and are re-read at most every
/// `slowProbeInterval` seconds (cached values are returned in between).
public actor MetricsSampler {
    private let cpuReader = CPUReader()
    private var network = NetworkAccumulator()
    private let processReader = ProcessReader()
    private let slowProbeInterval: TimeInterval
    private var disk: (sample: DiskSample?, at: TimeInterval)?
    private var battery: (info: BatteryInfo?, at: TimeInterval)?

    /// - Parameter slowProbeInterval: minimum seconds between disk and battery reads (0 = every sample).
    public init(slowProbeInterval: TimeInterval = 10) {
        self.slowProbeInterval = slowProbeInterval
    }

    public func sample(includeProcesses: Bool, includeTemperature: Bool) -> MetricsSnapshot {
        let now = NetworkReader.monotonicSeconds()
        let cpu = cpuReader.read()
        let memory = MemoryReader.read()
        let networkSample = network.update(NetworkReader.counters(), at: now)

        if disk == nil || now - disk!.at >= slowProbeInterval {
            disk = (DiskReader.read(path: "/"), now)
        }
        if battery == nil || now - battery!.at >= slowProbeInterval {
            battery = (BatteryReader.read(), now)
        }

        return MetricsSnapshot(
            date: Date(),
            cpu: cpu,
            memory: memory,
            disk: disk?.sample,
            network: networkSample,
            battery: battery?.info,
            temperatureCelsius: includeTemperature ? TemperatureReader.socCelsius() : nil,
            processes: includeProcesses ? processReader.read() : []
        )
    }

    /// Forces the next `sample` to re-read disk and battery (e.g. after a cleanup or a power-source change).
    public func invalidateSlowProbes() {
        disk = nil
        battery = nil
    }
}
