import Foundation

/// Index of a node inside a `ScanTree`. Only meaningful for the tree that produced it.
public struct NodeID: Hashable, Sendable, Codable {
    public let raw: Int32
    public init(raw: Int32) { self.raw = raw }
    @inline(__always) var index: Int { Int(raw) }
}

/// A resolved view of one node (directory, or a file at least `largeFileThreshold` bytes).
public struct ScanNodeInfo: Sendable, Identifiable, Hashable {
    public let id: NodeID
    public let name: String
    /// Path as the user knows it (for a scan of "/", firmlinked paths such as `/Users/…`).
    public let path: String
    public let isDirectory: Bool
    /// Allocated bytes on disk (all forks), aggregated for directories.
    public let bytes: Int64
    /// Files under the node (1 for a file node). Hard-linked files count once.
    public let fileCount: Int
    /// Most recent modification date in the subtree.
    public let modified: Date
    /// True when the folder (or the folder itself only, not its parents) could not be read.
    public let isUnreadable: Bool
}

public struct ScanProgress: Sendable {
    public var filesCounted: Int
    public var bytesCounted: Int64
    public var currentPath: String
    public var elapsed: TimeInterval
    public var unreadableCount: Int
    /// Folders read so far (added to the contract; useful for "N folders" UI and benchmarks).
    public var directoriesRead: Int

    public init(filesCounted: Int, bytesCounted: Int64, currentPath: String, elapsed: TimeInterval, unreadableCount: Int, directoriesRead: Int = 0) {
        self.filesCounted = filesCounted
        self.bytesCounted = bytesCounted
        self.currentPath = currentPath
        self.elapsed = elapsed
        self.unreadableCount = unreadableCount
        self.directoriesRead = directoriesRead
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case finished(ScanTree)
}

public enum ScanError: Error, Sendable, Equatable {
    case rootNotFound(String)
    case rootNotADirectory(String)
    case rootUnreadable(String, errno: Int32)
}

/// How a rescan was carried out. Read it from `DiskScanner.lastRescan` after a rescan stream finishes.
public struct RescanSummary: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// FSEvents history was replayed and only the changed folders were read again.
        case incremental
        /// "Rescan this folder": the folder's whole subtree was read again.
        case folder
        /// A full scan was needed.
        case full(FullScanReason)
    }
    public enum FullScanReason: String, Sendable, Equatable {
        case noEventHistory          // tree has no event id, or the device's event database changed
        case historyUnavailable      // the stream could not start or did not finish replaying
        case mustScanSubDirs         // FSEvents coalesced or dropped events
        case rootChanged             // the scanned root moved or was replaced
        case pathOutsideTree         // a changed path could not be mapped into the tree
    }
    public var mode: Mode
    /// Logical paths of the folders that were read again (empty for a full scan).
    public var changedDirectories: [String]
    /// Number of folders actually listed from disk.
    public var directoriesRead: Int
    public var elapsed: TimeInterval
}

/// Scanner tuning. Defaults suit a full scan of the startup disk.
public struct ScanConfiguration: Sendable {
    /// Files at least this large become nodes (for the treemap and the large-file list).
    public var largeFileThreshold: Int64
    /// Folders read in parallel.
    public var concurrency: Int
    /// Minimum interval between progress events (0.1 s ⇒ at most 10 per second).
    public var progressInterval: TimeInterval
    /// Buffer handed to each `getattrlistbulk` call.
    public var bulkBufferSize: Int
    /// Testing hook: sleep this long before reading each folder.
    var testingDirectoryDelay: TimeInterval = 0

    public init(largeFileThreshold: Int64 = 50_000_000,
                concurrency: Int = max(4, min(32, ProcessInfo.processInfo.activeProcessorCount * 2)),
                progressInterval: TimeInterval = 0.1,
                bulkBufferSize: Int = 128 * 1024) {
        self.largeFileThreshold = largeFileThreshold
        self.concurrency = max(1, concurrency)
        self.progressInterval = max(0.1, progressInterval)
        self.bulkBufferSize = max(16 * 1024, bulkBufferSize)
    }
}
