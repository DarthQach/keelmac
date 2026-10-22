import Foundation

public enum DiskReader {
    /// Capacity of the volume containing `path` (the startup volume for "/").
    public static func read(path: String = "/") -> DiskSample? {
        // A fresh URL each time: URL caches resource values on the instance.
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeNameKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else {
            return nil
        }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        return DiskSample(
            volumeName: values.volumeName ?? "",
            totalBytes: Int64(total),
            availableBytes: min(Int64(total), max(0, available))
        )
    }
}
