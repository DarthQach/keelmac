import Darwin

/// Thin wrappers over `sysctlbyname`.
enum Sysctl {
    /// Reads a fixed-size value (integer or C struct). Returns nil on failure or size mismatch.
    static func value<T>(_ name: String, as type: T.Type, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            sysctlbyname(name, pointer, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }

    static func uint64(_ name: String) -> UInt64? { value(name, as: UInt64.self, initial: 0) }
    static func int32(_ name: String) -> Int32? { value(name, as: Int32.self, initial: 0) }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        if let end = buffer.firstIndex(of: 0) { buffer.removeSubrange(end...) }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Mach absolute time ↔ nanoseconds.
struct Timebase: Sendable, Equatable {
    let numer: UInt64
    let denom: UInt64

    static let current: Timebase = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return Timebase(numer: 1, denom: 1) }
        return Timebase(numer: UInt64(info.numer), denom: UInt64(info.denom))
    }()

    func nanoseconds(_ ticks: UInt64) -> UInt64 {
        if numer == denom { return ticks }
        // Split to avoid overflow for large tick counts.
        let (q, r) = ticks.quotientAndRemainder(dividingBy: denom)
        return q * numer + r * numer / denom
    }
}

/// The host port, obtained once (each `mach_host_self()` call adds a send right).
let hostPort: mach_port_t = mach_host_self()
