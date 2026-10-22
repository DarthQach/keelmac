import Darwin
import Foundation
import Testing
@testable import MetricsKit

/// Read-only checks against the live system: plausible ranges, not exact values.
@Suite("Live system", .serialized)
struct LiveSmokeTests {
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func milliseconds(_ body: () async -> Void) async -> (wall: Double, cpu: Double) {
        let cpu0 = cpuSeconds()
        let start = ContinuousClock.now
        await body()
        let elapsed = ContinuousClock.now - start
        let wall = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return (wall, (cpuSeconds() - cpu0) * 1_000)
    }

    @Test func firstSampleHasNoRatesSecondDoes() async throws {
        let sampler = MetricsSampler()
        let first = await sampler.sample(includeProcesses: false, includeTemperature: false)
        #expect(first.cpu == nil)
        #expect(first.network == nil)
        try await Task.sleep(for: .milliseconds(300))
        let second = await sampler.sample(includeProcesses: false, includeTemperature: false)

        let cpu = try #require(second.cpu)
        #expect((0...1).contains(cpu.total))
        #expect((0...1).contains(cpu.user) && (0...1).contains(cpu.system))
        #expect(cpu.perCore.count == ProcessInfo.processInfo.processorCount)
        #expect(cpu.perCore.allSatisfy { (0...1).contains($0) })

        let memory = try #require(second.memory)
        #expect(memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.usedBytes > 0 && memory.usedBytes < memory.totalBytes)
        #expect(memory.appBytes + memory.wiredBytes + memory.compressedBytes >= memory.usedBytes)

        let disk = try #require(second.disk)
        #expect(disk.totalBytes > 0)
        #expect(disk.availableBytes > 0 && disk.availableBytes <= disk.totalBytes)
        #expect(!disk.volumeName.isEmpty)

        let network = try #require(second.network)
        #expect(network.bytesInPerSecond >= 0 && network.bytesOutPerSecond >= 0)

        let battery = try #require(second.battery)
        if battery.isPresent {
            #expect((0...100).contains(try #require(battery.chargePercent)))
            #expect(try #require(battery.cycleCount) >= 0)
            #expect((1...100).contains(try #require(battery.maxCapacityPercent)))
        }
        print("[MetricsKit] cpu \(String(format: "%.1f", cpu.total * 100))% user \(String(format: "%.1f", cpu.user * 100))% sys \(String(format: "%.1f", cpu.system * 100))%")
        print("[MetricsKit] memory used \(memory.usedBytes) app \(memory.appBytes) wired \(memory.wiredBytes) compressed \(memory.compressedBytes) cached \(memory.cachedBytes) swap \(memory.swapUsedBytes) pressure \(memory.pressure)")
        print("[MetricsKit] disk \(disk.volumeName) total \(disk.totalBytes) available \(disk.availableBytes)")
        print("[MetricsKit] battery \(battery)")
    }

    @Test func processesArePlausible() async throws {
        let sampler = MetricsSampler()
        _ = await sampler.sample(includeProcesses: true, includeTemperature: false)
        try await Task.sleep(for: .milliseconds(500))
        let processes = await sampler.sample(includeProcesses: true, includeTemperature: false).processes
        #expect(processes.count >= 50)
        let me = try #require(processes.first { $0.id == getpid() })
        #expect(me.isOwnedByCurrentUser)
        #expect(!me.isRestricted)
        #expect(me.memoryBytes > 0)
        #expect(me.userName == NSUserName())
        #expect(processes.contains { $0.uid == 0 && !$0.name.isEmpty })   // root processes listed with what's readable
        #expect(processes.allSatisfy { $0.cpuPercent >= 0 })
        #expect(Set(processes.map(\.id)).count == processes.count)
        let topCPU = processes.prefix(5).map { "\($0.name) \(String(format: "%.1f", $0.cpuPercent))%" }
        let topMemory = processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(5).map { "\($0.name) \($0.memoryBytes / 1_048_576) MB" }
        let withBundle = processes.filter { $0.bundleIdentifier != nil }.count
        print("[MetricsKit] processes \(processes.count), restricted \(processes.filter(\.isRestricted).count), with bundle id \(withBundle)")
        print("[MetricsKit] top CPU \(topCPU)")
        print("[MetricsKit] top memory \(topMemory)")
    }

    @Test func temperatureIsPlausibleWhenAvailable() {
        guard let celsius = TemperatureReader.socCelsius() else {
            print("[MetricsKit] SoC temperature unavailable on this Mac")
            return
        }
        #expect((10...120).contains(celsius))
        print("[MetricsKit] SoC temperature \(String(format: "%.1f", celsius)) °C")
    }

    @Test func systemInfo() {
        let info = SystemInfo.current()
        #expect(!info.chip.isEmpty)
        #expect(!info.modelIdentifier.isEmpty)
        #expect(!info.modelName.isEmpty)
        #expect(info.coreCount > 0)
        #expect(info.memoryBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(info.bootDate < Date() && info.uptime() > 0)
        #expect(info.macOSVersion.hasPrefix("\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)."))
        print("[MetricsKit] \(info)")
    }

    @Test func sampleWithoutProcessesIsUnderFiftyMilliseconds() async {
        let sampler = MetricsSampler()
        _ = await sampler.sample(includeProcesses: false, includeTemperature: false)  // warm caches
        var worst = 0.0
        for _ in 0..<5 {
            let cost = await Self.milliseconds { _ = await sampler.sample(includeProcesses: false, includeTemperature: false) }
            worst = max(worst, cost.wall)
        }
        #expect(worst < 50)
        // Including the disk read, as it runs every `diskInterval`.
        let slow = MetricsSampler(diskInterval: 0)
        _ = await slow.sample(includeProcesses: false, includeTemperature: false)
        let slowCost = await Self.milliseconds { _ = await slow.sample(includeProcesses: false, includeTemperature: false) }
        print("[MetricsKit] sample() basic worst of 5: \(String(format: "%.2f", worst)) ms; with disk: \(String(format: "%.2f", slowCost.wall)) ms wall, \(String(format: "%.2f", slowCost.cpu)) ms CPU")
    }

    @Test func measureFullSampleCost() async {
        let sampler = MetricsSampler()
        _ = await sampler.sample(includeProcesses: true, includeTemperature: true)  // discovery + identity caches
        var walls: [Double] = [], cpus: [Double] = []
        for _ in 0..<5 {
            let cost = await Self.milliseconds { _ = await sampler.sample(includeProcesses: true, includeTemperature: true) }
            walls.append(cost.wall)
            cpus.append(cost.cpu)
        }
        let temperature = await Self.milliseconds { _ = TemperatureReader.socCelsius() }
        let processSampler = MetricsSampler()
        _ = await processSampler.sample(includeProcesses: true, includeTemperature: false)
        let processes = await Self.milliseconds { _ = await processSampler.sample(includeProcesses: true, includeTemperature: false) }
        func fmt(_ values: [Double]) -> String { String(format: "median %.1f ms (min %.1f, max %.1f)", values.sorted()[values.count / 2], values.min() ?? 0, values.max() ?? 0) }
        print("[MetricsKit] sample(processes+temperature): wall \(fmt(walls)); CPU \(fmt(cpus))")
        print("[MetricsKit]   temperature alone \(String(format: "%.1f", temperature.wall)) ms wall / \(String(format: "%.2f", temperature.cpu)) ms CPU; processes alone \(String(format: "%.1f", processes.wall)) ms wall / \(String(format: "%.1f", processes.cpu)) ms CPU")
        #expect(walls.allSatisfy { $0 > 0 })
    }
}
