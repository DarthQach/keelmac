import Darwin
import Foundation

/// Pure per-process CPU arithmetic.
public enum ProcessMath {
    /// CPU percent (100 = one core) from two cumulative CPU-time readings in Mach absolute-time units
    /// (`pti_total_user + pti_total_system`) taken `elapsedNanoseconds` apart.
    public static func cpuPercent(
        previousTicks: UInt64, currentTicks: UInt64, elapsedNanoseconds: UInt64,
        timebaseNumer: UInt64, timebaseDenom: UInt64
    ) -> Double {
        guard elapsedNanoseconds > 0, currentTicks >= previousTicks, timebaseDenom > 0 else { return 0 }
        let timebase = Timebase(numer: timebaseNumer, denom: timebaseDenom)
        let cpuNanoseconds = timebase.nanoseconds(currentTicks - previousTicks)
        return max(0, Double(cpuNanoseconds) / Double(elapsedNanoseconds) * 100)
    }

    /// The bundle path of the innermost `.app` that contains `executablePath`
    /// (".../Foo.app/Contents/MacOS/foo" → ".../Foo.app"), or nil.
    public static func appBundlePath(forExecutable executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }
}

/// Stateful libproc sampler. Owned by `MetricsSampler` (not thread-safe on its own).
final class ProcessReader {
    private struct Identity {
        let comm: String
        let name: String
        let path: String?
        let bundleIdentifier: String?
    }

    private var previousCPU: [Int32: UInt64] = [:]
    private var previousTime: UInt64?
    private var identities: [Int32: Identity] = [:]
    private var userNames: [UInt32: String] = [:]
    private var bundleIDs: [String: String?] = [:]
    private let currentUID = getuid()
    private let timebase = Timebase.current

    func read() -> [ProcessSample] {
        let pids = Self.allPIDs()
        let now = mach_absolute_time()
        let elapsed = previousTime.map { timebase.nanoseconds(now &- $0) } ?? 0
        var nextCPU: [Int32: UInt64] = [:]
        nextCPU.reserveCapacity(pids.count)
        var seen = Set<Int32>()
        seen.reserveCapacity(pids.count)
        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)

        for pid in pids {
            // Short BSD info is readable for every process (uid + 16-char command name).
            var short = proc_bsdshortinfo()
            let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else { continue }
            seen.insert(pid)
            let uid = short.pbsi_uid
            let comm = Self.string(fromTuple: short.pbsi_comm)
            let identity = identity(pid: pid, comm: comm)

            var cpuPercent = 0.0
            var memory: UInt64 = 0
            var restricted = true
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
                restricted = false
                let ticks = task.pti_total_user &+ task.pti_total_system
                nextCPU[pid] = ticks
                if let previous = previousCPU[pid], elapsed > 0 {
                    cpuPercent = ProcessMath.cpuPercent(
                        previousTicks: previous, currentTicks: ticks, elapsedNanoseconds: elapsed,
                        timebaseNumer: timebase.numer, timebaseDenom: timebase.denom
                    )
                }
                memory = Self.physicalFootprint(pid) ?? task.pti_resident_size
            }

            samples.append(ProcessSample(
                id: pid,
                name: identity.name,
                userName: userName(uid),
                uid: uid,
                cpuPercent: cpuPercent,
                memoryBytes: memory,
                bundleIdentifier: identity.bundleIdentifier,
                isOwnedByCurrentUser: uid == currentUID,
                path: identity.path,
                isRestricted: restricted
            ))
        }

        previousCPU = nextCPU
        previousTime = now
        if identities.count > seen.count { identities = identities.filter { seen.contains($0.key) } }
        samples.sort { ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes) }
        return samples
    }

    // MARK: - Identity (cached per pid; refreshed when the command name changes, i.e. pid reuse or exec)

    private func identity(pid: Int32, comm: String) -> Identity {
        if let cached = identities[pid], cached.comm == comm { return cached }
        let path = Self.executablePath(pid)
        // The executable's file name is untruncated; proc_name (32 chars) and comm (16 chars) are fallbacks.
        var name = path.map { ($0 as NSString).lastPathComponent } ?? ""
        if name.isEmpty { name = Self.procName(pid) ?? "" }
        if name.isEmpty { name = comm }
        if name.isEmpty { name = String(pid) }
        let bundleID = path.flatMap { bundleIdentifier(forExecutable: $0) }
        let identity = Identity(comm: comm, name: name, path: path, bundleIdentifier: bundleID)
        identities[pid] = identity
        return identity
    }

    private func bundleIdentifier(forExecutable path: String) -> String? {
        guard let bundlePath = ProcessMath.appBundlePath(forExecutable: path) else { return nil }
        if let cached = bundleIDs[bundlePath] { return cached }
        let plistURL = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        var identifier: String?
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            identifier = plist["CFBundleIdentifier"] as? String
        }
        bundleIDs[bundlePath] = identifier
        return identifier
    }

    private func userName(_ uid: UInt32) -> String {
        if let cached = userNames[uid] { return cached }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        var name = String(uid)
        if getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0, result != nil, let raw = entry.pw_name {
            name = String(cString: raw)
        }
        userNames[uid] = name
        return name
    }

    // MARK: - libproc

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    static func physicalFootprint(_ pid: Int32) -> UInt64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func procName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func string<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
