import Darwin

/// Pure memory arithmetic (Activity Monitor's definitions).
public enum MemoryMath {
    /// - Parameters:
    ///   - vm: counters from `host_statistics64(HOST_VM_INFO64)`; all counts are pages.
    ///   - pageSize: the host page size in bytes (16 KiB on Apple silicon).
    public static func sample(
        vm: vm_statistics64, pageSize: UInt64, totalBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressure
    ) -> MemorySample {
        let internalPages = UInt64(vm.internal_page_count)
        let purgeablePages = UInt64(vm.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let app = appPages * pageSize
        let wired = UInt64(vm.wire_count) * pageSize
        let compressed = UInt64(vm.compressor_page_count) * pageSize
        let cached = (UInt64(vm.external_page_count) + purgeablePages) * pageSize
        let used = app + wired + compressed
        return MemorySample(
            totalBytes: totalBytes,
            usedBytes: totalBytes > 0 ? min(used, totalBytes) : used,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            swapUsedBytes: swapUsedBytes,
            pressure: pressure
        )
    }
}

enum MemoryReader {
    static let totalBytes: UInt64 = Sysctl.uint64("hw.memsize") ?? 0
    static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        if host_page_size(hostPort, &size) == KERN_SUCCESS, size > 0 { return UInt64(size) }
        return UInt64(Sysctl.int32("hw.pagesize") ?? 16_384)
    }()

    static func read() -> MemorySample? {
        guard let vm = vmStatistics() else { return nil }
        return MemoryMath.sample(
            vm: vm, pageSize: pageSize, totalBytes: totalBytes,
            swapUsedBytes: swapUsedBytes() ?? 0, pressure: pressure()
        )
    }

    static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    static func swapUsedBytes() -> UInt64? {
        Sysctl.value("vm.swapusage", as: xsw_usage.self, initial: xsw_usage()).map { $0.xsu_used }
    }

    static func pressure() -> MemoryPressure {
        Sysctl.int32("kern.memorystatus_vm_pressure_level").flatMap { MemoryPressure(rawValue: Int($0)) } ?? .normal
    }
}
