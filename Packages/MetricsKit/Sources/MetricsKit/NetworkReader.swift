import Darwin
import Foundation

/// Raw byte counters of one interface from `if_data` (32-bit, wrap at 4 GiB).
public struct InterfaceCounters: Sendable, Equatable {
    public let name: String
    public let bytesIn: UInt32
    public let bytesOut: UInt32

    public init(name: String, bytesIn: UInt32, bytesOut: UInt32) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Pure, testable network-rate state machine. Feed it counter snapshots; it returns rates from deltas.
public struct NetworkAccumulator: Sendable {
    private var last: [String: InterfaceCounters] = [:]
    private var lastTime: TimeInterval?
    private var totalIn: UInt64 = 0
    private var totalOut: UInt64 = 0

    public init() {}

    /// Bytes transferred between two readings of a 32-bit counter, assuming at most one wrap.
    public static func delta(_ old: UInt32, _ new: UInt32) -> UInt64 { UInt64(new &- old) }

    /// Updates with a snapshot taken at `time` (seconds, monotonic). Returns nil on the first call.
    /// Interfaces seen for the first time contribute their current counter to the totals but nothing to the rate;
    /// interfaces that disappeared are forgotten.
    public mutating func update(_ counters: [InterfaceCounters], at time: TimeInterval) -> NetworkSample? {
        var deltaIn: UInt64 = 0, deltaOut: UInt64 = 0
        var next: [String: InterfaceCounters] = [:]
        next.reserveCapacity(counters.count)
        for counter in counters {
            if let old = last[counter.name] {
                deltaIn += Self.delta(old.bytesIn, counter.bytesIn)
                deltaOut += Self.delta(old.bytesOut, counter.bytesOut)
            } else {
                totalIn += UInt64(counter.bytesIn)
                totalOut += UInt64(counter.bytesOut)
            }
            next[counter.name] = counter
        }
        totalIn += deltaIn
        totalOut += deltaOut
        last = next
        defer { lastTime = time }
        guard let lastTime else { return nil }
        let elapsed = time - lastTime
        guard elapsed > 0 else {
            return NetworkSample(bytesInPerSecond: 0, bytesOutPerSecond: 0, totalIn: totalIn, totalOut: totalOut)
        }
        return NetworkSample(
            bytesInPerSecond: Double(deltaIn) / elapsed,
            bytesOutPerSecond: Double(deltaOut) / elapsed,
            totalIn: totalIn,
            totalOut: totalOut
        )
    }
}

enum NetworkReader {
    /// `getifaddrs` AF_LINK entries of interfaces that are up and not loopback.
    static func counters() -> [InterfaceCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceCounters] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let data = entry.pointee.ifa_data else { continue }
            let ifData = data.assumingMemoryBound(to: if_data.self).pointee
            result.append(InterfaceCounters(
                name: String(cString: entry.pointee.ifa_name),
                bytesIn: ifData.ifi_ibytes,
                bytesOut: ifData.ifi_obytes
            ))
        }
        return result
    }

    static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}
