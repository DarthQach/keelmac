import Foundation
import MetricsKit
import ReportKit
import SafetyKit

/// One point of the 60-minute history.
struct HistoryPoint: Sendable, Identifiable {
    let date: Date
    let cpu: Double?
    let memoryUsedFraction: Double?
    let pressure: MemoryPressure?
    let netIn: Double?
    let netOut: Double?
    let temperature: Double?
    var id: Date { date }
}

/// Samples the Mac on a timer for the menu bar, Monitor and Dashboard (C3–C7).
/// Processes and temperature are only sampled while something on screen shows them.
@MainActor
@Observable
final class MetricsMonitor {
    private(set) var latest: MetricsSnapshot?
    private(set) var history = RingBuffer<HistoryPoint>(capacity: 1_800)
    private(set) var processes: [ProcessSample] = []
    private(set) var battery: BatteryInfo?
    let systemInfo = SystemInfo.current()

    private let sampler = MetricsSampler()
    private var loop: Task<Void, Never>?
    private var detailedConsumers = 0
    private var batteryReport: BatterySystemReport?
    private var batteryReportDate: Date?
    private var alertEngine: AlertEngine
    var onAlert: (@MainActor ([AlertEvent]) -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: "alertEngine"), let engine = try? JSONDecoder().decode(AlertEngine.self, from: data) {
            alertEngine = engine
        } else {
            alertEngine = AlertEngine(thresholds: MetricsMonitor.thresholds())
        }
    }

    static func thresholds() -> AlertThresholds {
        let d = UserDefaults.standard
        guard d.bool(forKey: Preferences.Key.alertsEnabled) else {
            return AlertThresholds(diskFreeBelowBytes: nil, memoryRedMinutes: nil, temperatureAboveCelsius: nil, batteryCapacityBelowPercent: nil)
        }
        return AlertThresholds(
            diskFreeBelowBytes: Int64(d.double(forKey: Preferences.Key.alertDiskFreeGB) * 1_000_000_000),
            memoryRedMinutes: d.integer(forKey: Preferences.Key.alertMemoryRedMinutes),
            temperatureAboveCelsius: d.double(forKey: Preferences.Key.alertTemperatureC),
            batteryCapacityBelowPercent: d.double(forKey: Preferences.Key.alertBatteryPercent))
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = max(1, min(10, UserDefaults.standard.double(forKey: Preferences.Key.refreshInterval)))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Call from views that show processes or temperature (popover, Monitor, Dashboard).
    func beginDetailed() {
        detailedConsumers += 1
        if detailedConsumers == 1 { Task { await tick() } }
    }

    func endDetailed() { detailedConsumers = max(0, detailedConsumers - 1) }

    private var menuBarWantsTemperature: Bool {
        MenuBarItem.decode(UserDefaults.standard.string(forKey: Preferences.Key.menuBarItems) ?? "").contains(.temperature)
    }

    private func tick() async {
        let detailed = detailedConsumers > 0
        let snapshot = await sampler.sample(includeProcesses: detailed, includeTemperature: detailed || menuBarWantsTemperature)
        latest = snapshot
        if detailed { processes = snapshot.processes }
        await refreshBatteryReportIfNeeded()
        if var b = snapshot.battery {
            if let report = batteryReport { b = b.applying(report) }
            battery = b
        }
        let memFraction = snapshot.memory.map { Double($0.usedBytes) / Double(max($0.totalBytes, 1)) }
        history.append(HistoryPoint(date: snapshot.date, cpu: snapshot.cpu?.total, memoryUsedFraction: memFraction, pressure: snapshot.memory?.pressure,
                                    netIn: snapshot.network?.bytesInPerSecond, netOut: snapshot.network?.bytesOutPerSecond,
                                    temperature: snapshot.temperatureCelsius ?? latestTemperatureFallback))
        evaluateAlerts(snapshot)
    }

    private var latestTemperatureFallback: Double? { nil }

    /// The temperature to show: SoC when readable, otherwise the battery's.
    var temperature: Double? { latest?.temperatureCelsius ?? battery?.temperatureCelsius }

    /// System Information's exact battery capacity comes from system_profiler (once an hour).
    private func refreshBatteryReportIfNeeded() async {
        guard latest?.battery?.isPresent == true else { return }
        if let d = batteryReportDate, Date().timeIntervalSince(d) < 3600 { return }
        batteryReportDate = Date()
        let result = await ProcessCommandRunner().run(BatteryReader.systemProfilerExecutable, BatteryReader.systemProfilerArguments, timeout: 20)
        if result.succeeded, let report = BatteryReader.parseSystemProfiler(json: Data(result.stdout.utf8)) { batteryReport = report }
    }

    private func evaluateAlerts(_ s: MetricsSnapshot) {
        alertEngine.update(thresholds: MetricsMonitor.thresholds())
        let sample = AlertSample(date: s.date, diskAvailable: s.disk?.availableBytes, pressure: s.memory?.pressure.rawValue,
                                 temperatureCelsius: s.temperatureCelsius, batteryMaxCapacityPercent: battery?.maxCapacityPercent)
        let events = alertEngine.evaluate(sample)
        if !events.isEmpty {
            onAlert?(events)
            UserDefaults.standard.set(try? JSONEncoder().encode(alertEngine), forKey: "alertEngine")
        }
    }

    /// Minutes covered by the history buffer (up to 60).
    var historyMinutes: Double {
        guard let first = history.first, let last = history.last else { return 0 }
        return min(60, last.date.timeIntervalSince(first.date) / 60)
    }

    /// Fractions of the last hour spent in warning and critical memory pressure (for the Health Score).
    var pressureFractions: (warning: Double, critical: Double) {
        let points = history.elements.compactMap(\.pressure)
        guard !points.isEmpty else { return (0, 0) }
        let n = Double(points.count)
        return (Double(points.filter { $0 == .warning }.count) / n, Double(points.filter { $0 == .critical }.count) / n)
    }
}
