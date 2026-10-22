import Darwin
import Testing
@testable import MetricsKit

@Suite("CPU math")
struct CPUMathTests {
    @Test func totalUserSystemAndPerCoreFromTickDeltas() throws {
        let previous = [
            CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 1_000, nice: 0),
        ]
        // Core 0: +60 user, +20 system, +20 idle (80% busy). Core 1: +100 idle (0% busy).
        let current = [
            CPUTicks(user: 160, system: 70, idle: 870, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 1_100, nice: 0),
        ]
        let sample = try #require(CPUMath.sample(previous: previous, current: current))
        #expect(abs(sample.perCore[0] - 0.8) < 1e-9)
        #expect(sample.perCore[1] == 0)
        #expect(abs(sample.user - 0.3) < 1e-9)    // 60 / 200
        #expect(abs(sample.system - 0.1) < 1e-9)  // 20 / 200
        #expect(abs(sample.total - 0.4) < 1e-9)
    }

    @Test func niceCountsAsUser() throws {
        let sample = try #require(CPUMath.sample(
            previous: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
            current: [CPUTicks(user: 10, system: 0, idle: 70, nice: 20)]
        ))
        #expect(abs(sample.user - 0.3) < 1e-9)
        #expect(abs(sample.total - 0.3) < 1e-9)
    }

    @Test func counterWrapIsHandled() throws {
        let sample = try #require(CPUMath.sample(
            previous: [CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 49, nice: 0)],
            current: [CPUTicks(user: 40, system: 0, idle: 50, nice: 0)]  // +50 user, +100 idle
        ))
        #expect(abs(sample.total - 50.0 / 150.0) < 1e-9)
    }

    @Test func noElapsedTicksIsZeroAndMismatchedCoresIsNil() {
        let ticks = [CPUTicks(user: 5, system: 5, idle: 5, nice: 0)]
        #expect(CPUMath.sample(previous: ticks, current: ticks)?.total == 0)
        #expect(CPUMath.sample(previous: ticks, current: ticks + ticks) == nil)
        #expect(CPUMath.sample(previous: [], current: []) == nil)
    }
}

@Suite("Memory math")
struct MemoryMathTests {
    @Test func activityMonitorFormula() {
        var vm = vm_statistics64()
        vm.internal_page_count = 1_000
        vm.purgeable_count = 100
        vm.external_page_count = 300
        vm.wire_count = 200
        vm.compressor_page_count = 50
        vm.free_count = 400
        let page: UInt64 = 16_384
        let sample = MemoryMath.sample(
            vm: vm, pageSize: page, totalBytes: 10_000 * page, swapUsedBytes: 42, pressure: .warning
        )
        #expect(sample.appBytes == 900 * page)
        #expect(sample.wiredBytes == 200 * page)
        #expect(sample.compressedBytes == 50 * page)
        #expect(sample.cachedBytes == 400 * page)       // external + purgeable
        #expect(sample.usedBytes == 1_150 * page)       // app + wired + compressed
        #expect(sample.swapUsedBytes == 42)
        #expect(sample.pressure == .warning)
    }

    @Test func purgeableLargerThanInternalDoesNotUnderflowAndUsedIsCapped() {
        var vm = vm_statistics64()
        vm.internal_page_count = 10
        vm.purgeable_count = 20
        vm.wire_count = 1_000
        let sample = MemoryMath.sample(vm: vm, pageSize: 4_096, totalBytes: 4_096 * 500, swapUsedBytes: 0, pressure: .normal)
        #expect(sample.appBytes == 0)
        #expect(sample.usedBytes == 4_096 * 500)
    }

    @Test func pressureRawValuesMatchKernel() {
        #expect(MemoryPressure(rawValue: 1) == .normal)
        #expect(MemoryPressure(rawValue: 2) == .warning)
        #expect(MemoryPressure(rawValue: 4) == .critical)
        #expect(MemoryPressure(rawValue: 3) == nil)
    }
}

@Suite("Network deltas")
struct NetworkTests {
    @Test func firstUpdateIsNilThenRatesFromDeltas() throws {
        var accumulator = NetworkAccumulator()
        #expect(accumulator.update([InterfaceCounters(name: "en0", bytesIn: 1_000, bytesOut: 500)], at: 10) == nil)
        let update = accumulator.update([InterfaceCounters(name: "en0", bytesIn: 5_000, bytesOut: 1_500)], at: 12)
        let sample = try #require(update)
        #expect(sample.bytesInPerSecond == 2_000)
        #expect(sample.bytesOutPerSecond == 500)
        #expect(sample.totalIn == 5_000)
        #expect(sample.totalOut == 1_500)
    }

    @Test func thirtyTwoBitWrap() throws {
        #expect(NetworkAccumulator.delta(UInt32.max - 99, 100) == 200)
        var accumulator = NetworkAccumulator()
        _ = accumulator.update([InterfaceCounters(name: "en0", bytesIn: UInt32.max - 999, bytesOut: 0)], at: 0)
        let update = accumulator.update([InterfaceCounters(name: "en0", bytesIn: 1_000, bytesOut: 0)], at: 1)
        let sample = try #require(update)
        #expect(sample.bytesInPerSecond == 2_000)
        #expect(sample.totalIn == UInt64(UInt32.max) - 999 + 2_000)  // totals keep growing past 4 GiB
    }

    @Test func multipleInterfacesSumAndNewInterfacesDoNotSpike() throws {
        var accumulator = NetworkAccumulator()
        _ = accumulator.update([InterfaceCounters(name: "en0", bytesIn: 100, bytesOut: 100)], at: 0)
        let update = accumulator.update([
            InterfaceCounters(name: "en0", bytesIn: 300, bytesOut: 200),
            InterfaceCounters(name: "utun3", bytesIn: 9_000_000, bytesOut: 9_000_000),  // just appeared
        ], at: 1)
        let sample = try #require(update)
        #expect(sample.bytesInPerSecond == 200)
        #expect(sample.bytesOutPerSecond == 100)
        let nextUpdate = accumulator.update([
            InterfaceCounters(name: "en0", bytesIn: 400, bytesOut: 200),
            InterfaceCounters(name: "utun3", bytesIn: 9_000_100, bytesOut: 9_000_000),
        ], at: 2)
        let next = try #require(nextUpdate)
        #expect(next.bytesInPerSecond == 200)
    }
}

@Suite("Ring buffer")
struct RingBufferTests {
    @Test func keepsOrderAndCapacity() {
        var buffer = RingBuffer<Int>(capacity: 3)
        #expect(buffer.isEmpty && buffer.last == nil && buffer.first == nil)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.elements == [1, 2])
        #expect(buffer.last == 2)
        buffer.append(3)
        buffer.append(4)
        buffer.append(5)
        #expect(buffer.count == 3)
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.first == 3)
        #expect(buffer.last == 5)
        #expect(buffer.isFull)
        buffer.removeAll()
        #expect(buffer.isEmpty)
    }

    @Test func sixtyMinutesAtTwoSeconds() {
        var buffer = RingBuffer<Double>(capacity: 1_800)
        buffer.append(contentsOf: (0..<5_000).map(Double.init))
        #expect(buffer.count == 1_800)
        #expect(buffer.elements.first == 3_200)
        #expect(buffer.elements.last == 4_999)
        #expect(buffer.elements == (3_200..<5_000).map(Double.init))
    }
}

@Suite("Process math")
struct ProcessMathTests {
    @Test func cpuPercentFromMachTimeDeltas() {
        // Apple silicon timebase 125/3: 24_000_000 ticks = 1 s of CPU. Over 2 s wall time = 50%.
        let percent = ProcessMath.cpuPercent(
            previousTicks: 1_000, currentTicks: 1_000 + 24_000_000, elapsedNanoseconds: 2_000_000_000,
            timebaseNumer: 125, timebaseDenom: 3
        )
        #expect(abs(percent - 50) < 1e-6)
    }

    @Test func multiCoreProcessExceedsOneHundred() {
        let percent = ProcessMath.cpuPercent(
            previousTicks: 0, currentTicks: 3_000_000_000, elapsedNanoseconds: 1_000_000_000,
            timebaseNumer: 1, timebaseDenom: 1
        )
        #expect(abs(percent - 300) < 1e-9)
    }

    @Test func decreasingTimeOrZeroElapsedIsZero() {
        #expect(ProcessMath.cpuPercent(previousTicks: 10, currentTicks: 5, elapsedNanoseconds: 1, timebaseNumer: 1, timebaseDenom: 1) == 0)
        #expect(ProcessMath.cpuPercent(previousTicks: 1, currentTicks: 5, elapsedNanoseconds: 0, timebaseNumer: 1, timebaseDenom: 1) == 0)
    }

    @Test func appBundlePathFromExecutable() {
        #expect(ProcessMath.appBundlePath(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
        #expect(ProcessMath.appBundlePath(forExecutable:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
            == "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app")
        #expect(ProcessMath.appBundlePath(forExecutable: "/usr/libexec/trustd") == nil)
    }

    @Test func timebaseConversionDoesNotOverflow() {
        let timebase = Timebase(numer: 125, denom: 3)
        #expect(timebase.nanoseconds(3) == 125)
        #expect(timebase.nanoseconds(UInt64.max / 100) > 0)
    }
}
