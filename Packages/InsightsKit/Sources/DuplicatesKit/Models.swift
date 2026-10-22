import Foundation

/// One file that has at least one byte-identical copy elsewhere.
public struct DuplicateFile: Sendable, Identifiable, Hashable, Codable {
    /// The absolute path.
    public let id: String
    public let path: String
    public let bytes: Int64
    public let modified: Date
    public let created: Date?

    public init(path: String, bytes: Int64, modified: Date, created: Date? = nil) {
        self.id = path
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.created = created
    }
}

/// Files whose full contents hash to the same SHA-256. Files are sorted by path.
public struct DuplicateGroup: Sendable, Identifiable, Hashable, Codable {
    /// Lowercase hex SHA-256 of the full contents.
    public let id: String
    public let bytesEach: Int64
    public let files: [DuplicateFile]

    public init(id: String, bytesEach: Int64, files: [DuplicateFile]) {
        self.id = id
        self.bytesEach = bytesEach
        self.files = files.sorted { $0.path < $1.path }
    }

    /// Space taken by every copy except one.
    public var wastedBytes: Int64 { bytesEach * Int64(max(files.count - 1, 0)) }
}

public struct DuplicateProgress: Sendable, Equatable {
    public enum Stage: String, Sendable, Codable, CaseIterable {
        /// Walking the chosen folders. `total` is 0 (unknown); `done` counts files seen.
        case listing
        /// Bucketing files by size. `done` and `total` count files.
        case groupingBySize
        /// Hashing the first and last 64 KB of same-size files.
        case hashingHeads
        /// Hashing the full contents of files whose heads and tails matched.
        case hashingFull
    }

    public let stage: Stage
    public let done: Int
    public let total: Int

    public init(stage: Stage, done: Int, total: Int) {
        self.stage = stage
        self.done = done
        self.total = total
    }

    /// 0…1 within the stage, nil when the total is unknown.
    public var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
}

/// Everything a search produced, including what it had to leave out.
public struct DuplicateSearchResult: Sendable, Equatable {
    /// Groups sorted by wasted bytes (largest first), then by hash.
    public let groups: [DuplicateGroup]
    /// Files or folders that couldn't be read (permission denied, vanished mid-scan). Sorted.
    public let unreadablePaths: [String]
    /// Files and folders skipped because `PathGuard` refuses them for `.userFile`.
    public let protectedSkipped: Int
    /// Regular files considered (after hidden, package, symlink, zero-byte and size filters).
    public let filesConsidered: Int

    public init(groups: [DuplicateGroup], unreadablePaths: [String], protectedSkipped: Int, filesConsidered: Int) {
        self.groups = groups
        self.unreadablePaths = unreadablePaths
        self.protectedSkipped = protectedSkipped
        self.filesConsidered = filesConsidered
    }

    public var totalWastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
}
