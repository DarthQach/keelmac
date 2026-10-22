import CoreServices
import Darwin
import Foundation

public struct LargeFile: Sendable, Identifiable, Hashable {
    public let id: String
    public let path: String
    public let bytes: Int64
    public let modified: Date
    public let lastOpened: Date?
    public init(path: String, bytes: Int64, modified: Date, lastOpened: Date?) {
        self.id = path; self.path = path; self.bytes = bytes; self.modified = modified; self.lastOpened = lastOpened
    }
}

public enum LargeFileFinder {
    /// Large files in the tree, largest first.
    /// - Parameters:
    ///   - minBytes: lower size bound. The tree only keeps files ≥ `tree.largeFileThreshold` (50 MB by default).
    ///   - notOpenedSince: keep only files last opened (or, when unknown, modified) before this date.
    ///   - lastOpened: last-opened lookup; inject a fake in tests, use `spotlightLastOpened` in the app.
    public static func find(in tree: ScanTree, minBytes: Int64, notOpenedSince: Date?,
                            lastOpened: (String) -> Date?) -> [LargeFile] {
        var out: [LargeFile] = []
        for id in tree.largeFileNodes {
            let bytes = tree.bytes(of: id)
            guard bytes >= minBytes else { continue }
            let info = tree.info(id)
            let opened = lastOpened(info.path)
            if let cutoff = notOpenedSince, (opened ?? info.modified) >= cutoff { continue }
            out.append(LargeFile(path: info.path, bytes: bytes, modified: info.modified, lastOpened: opened))
        }
        return out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    public static func find(in tree: ScanTree, minBytes: Int64, notOpenedSince: Date?) -> [LargeFile] {
        find(in: tree, minBytes: minBytes, notOpenedSince: notOpenedSince, lastOpened: spotlightLastOpened)
    }

    /// Spotlight's `kMDItemLastUsedDate`, falling back to the file's access time.
    public static func spotlightLastOpened(_ path: String) -> Date? {
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
           let value = MDItemCopyAttribute(item, kMDItemLastUsedDate), let date = value as? Date {
            return date
        }
        return accessDate(path)
    }

    static func accessDate(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let t = st.st_atimespec
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }
}
