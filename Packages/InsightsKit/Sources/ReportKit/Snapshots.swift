import Foundation

/// One storage snapshot: volume totals, battery capacity, reclaimable space, and the allocated size of
/// each measured folder keyed by its absolute path.
public struct SnapshotValue: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let volumeTotal: Int64
    public let volumeUsed: Int64
    public let batteryMaxCapacityPercent: Double?
    public let reclaimableBytes: Int64
    /// Absolute folder path → allocated bytes.
    public let entries: [String: Int64]

    public init(
        id: UUID = UUID(),
        date: Date,
        volumeTotal: Int64,
        volumeUsed: Int64,
        batteryMaxCapacityPercent: Double?,
        reclaimableBytes: Int64,
        entries: [String: Int64]
    ) {
        self.id = id
        self.date = date
        self.volumeTotal = volumeTotal
        self.volumeUsed = volumeUsed
        self.batteryMaxCapacityPercent = batteryMaxCapacityPercent
        self.reclaimableBytes = reclaimableBytes
        self.entries = entries
    }
}

/// How the app persists snapshots (SwiftData in App/Persistence); keeps ReportKit store-free.
public protocol SnapshotStoring: Sendable {
    func save(_ snapshot: SnapshotValue) async throws
    func all() async throws -> [SnapshotValue]
}

/// One folder's change between two snapshots. `oldBytes == nil` is a new folder, `newBytes == nil` a removed one.
public struct FolderChange: Sendable, Identifiable, Equatable, Codable {
    /// The folder's absolute path.
    public let id: String
    public let oldBytes: Int64?
    public let newBytes: Int64?
    /// `(newBytes ?? 0) − (oldBytes ?? 0)`.
    public let delta: Int64

    public init(path: String, oldBytes: Int64?, newBytes: Int64?) {
        self.id = path
        self.oldBytes = oldBytes
        self.newBytes = newBytes
        self.delta = (newBytes ?? 0) - (oldBytes ?? 0)
    }

    public var path: String { id }
    public var isNew: Bool { oldBytes == nil && newBytes != nil }
    public var isRemoved: Bool { oldBytes != nil && newBytes == nil }
}

public enum SnapshotDiff {
    /// Every folder in either snapshot, sorted by delta (largest growth first), ties by path.
    /// New folders count from 0, removed folders shrink to 0.
    public static func compare(old: SnapshotValue, new: SnapshotValue) -> [FolderChange] {
        let paths = Set(old.entries.keys).union(new.entries.keys)
        return paths
            .map { FolderChange(path: $0, oldBytes: old.entries[$0], newBytes: new.entries[$0]) }
            .sorted { $0.delta != $1.delta ? $0.delta > $1.delta : $0.id < $1.id }
    }
}

public enum SnapshotTaker {
    /// The ~/Library children measured on their own (the largest ones on a typical Mac). Library/Mobile
    /// Documents (iCloud Drive, often placeholders) and other protected folders are deliberately absent;
    /// ~/Library as a whole isn't measured.
    public static let libraryChildren = ["Developer", "Caches", "Containers", "Application Support", "Group Containers"]

    /// Folders a snapshot measures: the home's visible top-level folders (not ~/Library, not symlinks),
    /// sorted by name, then the `libraryChildren` that exist. Absolute paths.
    public static func folders(home: String) -> [String] {
        let fm = FileManager.default
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let top = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: base), includingPropertiesForKeys: keys,
                                               options: [.skipsHiddenFiles])) ?? []
        var out = top.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard name != "Library", isPlainDirectory(url, keys: keys) else { return nil }
            return base + "/" + name
        }.sorted()
        for child in libraryChildren {
            let path = base + "/Library/" + child
            if isPlainDirectory(URL(fileURLWithPath: path), keys: keys) { out.append(path) }
        }
        return out
    }

    /// Measures each of `folders` (default: `folders(home:)`) with `measure` and builds the snapshot.
    /// Measuring stops early if the task is cancelled; folders measured so far are kept.
    public static func take(
        home: String,
        volumeTotal: Int64,
        volumeUsed: Int64,
        battery: Double?,
        reclaimable: Int64,
        date: Date = Date(),
        id: UUID = UUID(),
        folders: [String]? = nil,
        measure: @Sendable (String) async -> Int64
    ) async -> SnapshotValue {
        var entries: [String: Int64] = [:]
        for folder in folders ?? self.folders(home: home) {
            if Task.isCancelled { break }
            entries[folder] = await measure(folder)
        }
        return SnapshotValue(id: id, date: date, volumeTotal: volumeTotal, volumeUsed: volumeUsed,
                             batteryMaxCapacityPercent: battery, reclaimableBytes: reclaimable, entries: entries)
    }

    /// Allocated bytes on disk under `path` (files' total allocated size, symlinks not followed or counted,
    /// unreadable items skipped). A symlink passed as `path` measures 0.
    public static func allocatedSize(of path: String) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let keySet = Set(keys)
        let root = URL(fileURLWithPath: path)
        guard let rootValues = try? root.resourceValues(forKeys: keySet), rootValues.isSymbolicLink != true else { return 0 }
        if rootValues.isRegularFile == true { return allocated(rootValues) }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true { total += allocated(values) }
        }
        return total
    }

    private static func allocated(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    private static func isPlainDirectory(_ url: URL, keys: [URLResourceKey]) -> Bool {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
