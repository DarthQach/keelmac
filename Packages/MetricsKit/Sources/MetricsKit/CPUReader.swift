import Darwin

/// Raw scheduler tick counters of one logical core (`processor_cpu_load_info`). Counters are 32-bit and wrap.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Pure CPU-load arithmetic, separated from the kernel calls so it can be tested.
public enum CPUMath {
    /// Load between two tick snapshots. Returns nil when the core count changed or the arrays are empty.
    public static func sample(previous: [CPUTicks], current: [CPUTicks]) -> CPUSample? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var sumUser: UInt64 = 0, sumSystem: UInt64 = 0, sumTotal: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        for (old, new) in zip(previous, current) {
            // Wrapping subtraction handles 32-bit counter rollover.
            let user = UInt64(new.user &- old.user) + UInt64(new.nice &- old.nice)
            let system = UInt64(new.system &- old.system)
            let idle = UInt64(new.idle &- old.idle)
            let total = user + system + idle
            perCore.append(total == 0 ? 0 : clamp(Double(user + system) / Double(total)))
            sumUser += user
            sumSystem += system
            sumTotal += total
        }
        guard sumTotal > 0 else {
            return CPUSample(total: 0, user: 0, system: 0, perCore: perCore)
        }
        let user = Double(sumUser) / Double(sumTotal)
        let system = Double(sumSystem) / Double(sumTotal)
        return CPUSample(total: clamp(user + system), user: clamp(user), system: clamp(system), perCore: perCore)
    }

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// Stateful reader: keeps the previous tick snapshot so each `read()` reports load since the last call.
final class CPUReader {
    private var previous: [CPUTicks]?

    /// Load since the previous call; nil on the first call.
    func read() -> CPUSample? {
        guard let current = Self.ticks() else { return nil }
        defer { previous = current }
        guard let previous else { return nil }
        return CPUMath.sample(previous: previous, current: current)
    }

    /// Current per-core tick counters from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
    static func ticks() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(currentTask, vm_address_t(UInt(bitPattern: info)), size)
        }
        let stride = Int(CPU_STATE_MAX)
        var ticks: [CPUTicks] = []
        ticks.reserveCapacity(Int(processorCount))
        for core in 0..<Int(processorCount) {
            let base = core * stride
            guard base + stride <= Int(infoCount) else { break }
            ticks.append(CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        return ticks
    }
}

/// This task's port, for `vm_deallocate`.
var currentTask: mach_port_t { mach_task_self_ }
