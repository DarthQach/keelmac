import Darwin
import Foundation

/// Path-prefix exclusions, compared against real (walkable) paths.
struct Exclusions: Sendable {
    let paths: [String]

    init(_ paths: [String]) { self.paths = paths.filter { !$0.isEmpty } }

    func contains(_ path: String) -> Bool {
        for e in paths where path == e || (path.hasPrefix(e) && path.utf8.count > e.utf8.count
                                           && path.utf8[path.utf8.index(path.utf8.startIndex, offsetBy: e.utf8.count)] == UInt8(ascii: "/")) {
            return true
        }
        return false
    }

    /// Normalizes user exclusions (logical or real, possibly through symlinks) to the tree's real paths.
    static func resolve(_ raw: [String], for tree: ScanTree) -> Exclusions {
        var out = Set<String>()
        for e in raw where !e.isEmpty {
            let expanded = ScanTree.normalize((e as NSString).expandingTildeInPath)
            var candidates = [expanded]
            if let real = realpath(expanded, nil) { candidates.append(String(cString: real)); free(real) }
            for c in candidates {
                out.insert(c)
                if let rel = tree.relativePath(for: c) { out.insert(ScanTree.join(tree.scanPath, rel)) }
            }
        }
        return Exclusions(Array(out))
    }
}

enum WorkMode: Sendable {
    case full
    /// Re-list this folder only; keep the old subtrees of subfolders that still exist.
    case shallow(old: Int32)
}

struct WorkItem: Sendable {
    var node: Int32
    var path: String
    var mode: WorkMode
}

/// Drives a bounded task group over folders and assembles a `ScanTree`.
/// Not Sendable: owned by the single task that runs the walk.
final class Walk {
    var tree: ScanTree
    let old: ScanTree?
    let config: ScanConfiguration
    let exclusions: Exclusions
    /// Old node ids to re-list (shallow) and to rescan entirely; old ids to drop.
    var changed = Set<Int32>()
    var fullRescan = Set<Int32>()
    var dropped = Set<Int32>()

    private var pending: [WorkItem] = []
    private let hardLinks = HardLinkSet()
    private let pool: BufferPool
    private let start = Date()
    private var lastProgress = Date.distantPast
    private(set) var filesCounted = 0
    private(set) var bytesCounted: Int64 = 0
    private(set) var directoriesRead = 0
    private(set) var unreadableCount = 0

    init(tree: ScanTree, old: ScanTree?, config: ScanConfiguration, exclusions: Exclusions) {
        self.tree = tree
        self.old = old
        self.config = config
        self.exclusions = exclusions
        self.pool = BufferPool(size: config.bulkBufferSize)
    }

    /// Full scan of the tree's scan path into a fresh root.
    func seedFullScan() {
        tree.appendNode(parent: -1, name: "", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
        pending.append(WorkItem(node: 0, path: tree.scanPath, mode: .full))
    }

    /// Incremental rebuild: copy `old`, re-listing `changed` and re-walking `fullRescan`.
    func seedFromOld() {
        guard let old, old.nodeCount > 0 else { seedFullScan(); return }
        copyFromOld(0, newParent: -1)
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(start) }

    func run(progress: (ScanProgress) -> Void) async throws {
        let width = config.concurrency
        let device = tree.deviceID
        let threshold = config.largeFileThreshold
        let hardLinks = self.hardLinks
        let pool = self.pool
        let delay = config.testingDirectoryDelay
        try await withThrowingTaskGroup(of: (WorkItem, DirListing).self) { group in
            var inflight = 0
            func launch() {
                while inflight < width, let item = pending.popLast() {
                    inflight += 1
                    group.addTask {
                        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
                        let listing = BulkReader.read(path: item.path, device: device, largeFileThreshold: threshold,
                                                      hardLinks: hardLinks, pool: pool, isCancelled: { Task.isCancelled })
                        return (item, listing)
                    }
                }
            }
            launch()
            while inflight > 0 {
                guard let (item, listing) = try await group.next() else { break }
                inflight -= 1
                if Task.isCancelled || listing.cancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
                merge(item, listing)
                launch()
                let now = Date()
                if now.timeIntervalSince(lastProgress) >= config.progressInterval {
                    lastProgress = now
                    progress(currentProgress(path: item.path))
                }
            }
        }
        try Task.checkCancellation()
    }

    func currentProgress(path: String) -> ScanProgress {
        ScanProgress(filesCounted: filesCounted, bytesCounted: bytesCounted, currentPath: tree.logicalPath(forReal: path),
                     elapsed: elapsed, unreadableCount: unreadableCount, directoriesRead: directoriesRead)
    }

    private func merge(_ item: WorkItem, _ listing: DirListing) {
        let n = Int(item.node)
        directoriesRead += 1
        if listing.errorCode != 0 {
            tree.flags[n] |= ScanTree.flagUnreadable
            unreadableCount += 1
            return
        }
        if listing.otherDevice { return }
        tree.ownBytes[n] = listing.ownBytes
        tree.ownFiles[n] = listing.ownFiles
        tree.ownModified[n] = max(tree.ownModified[n], listing.maxModified)
        filesCounted += Int(listing.ownFiles)
        bytesCounted += listing.ownBytes

        // For a shallow re-list, index the old folder's subdirectories by name.
        var oldChildren: [[UInt8]: Int32] = [:]
        var oldNode: Int32 = -1
        if case .shallow(let o) = item.mode, let old {
            oldNode = o
            let lo = Int(old.childOffsets[Int(o)]), hi = Int(old.childOffsets[Int(o) + 1])
            for k in lo..<hi {
                let c = Int(old.childIndex[k])
                if old.flags[c] & ScanTree.flagDirectory != 0 { oldChildren[old.rawName(c)] = Int32(c) }
            }
        }

        for e in listing.entries {
            if e.isDirectory {
                let name = listing.name(e)
                let path = ScanTree.join(item.path, name)
                if exclusions.contains(path) { continue }
                if oldNode >= 0, let oc = listing.withName(e, { oldChildren[Array($0)] }) {
                    copyFromOld(Int(oc), newParent: Int32(n))
                } else {
                    let c = listing.withName(e) {
                        tree.appendNode(parent: Int32(n), name: $0, isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: e.modified)
                    }
                    pending.append(WorkItem(node: c, path: path, mode: .full))
                }
            } else {
                listing.withName(e) {
                    _ = tree.appendNode(parent: Int32(n), name: $0, isDirectory: false, ownBytes: e.bytes, ownFiles: 1, ownModified: e.modified)
                }
            }
        }
    }

    /// Copies the old subtree at `oldIndex` under `newParent`, queueing work where the old data is stale.
    private func copyFromOld(_ oldIndex: Int, newParent: Int32) {
        guard let old else { return }
        var stack: [(Int, Int32)] = [(oldIndex, newParent)]
        while let (o, p) = stack.popLast() {
            if dropped.contains(Int32(o)) { continue }
            let isDir = old.flags[o] & ScanTree.flagDirectory != 0
            if !isDir {
                tree.appendCopy(of: o, from: old, parent: p, keepStats: true)
                continue
            }
            if fullRescan.contains(Int32(o)) {
                let c = tree.appendCopy(of: o, from: old, parent: p, keepStats: false)
                pending.append(WorkItem(node: c, path: old.realPath(ofIndex: o), mode: .full))
                continue
            }
            if changed.contains(Int32(o)) {
                let c = tree.appendCopy(of: o, from: old, parent: p, keepStats: false)
                pending.append(WorkItem(node: c, path: old.realPath(ofIndex: o), mode: .shallow(old: Int32(o))))
                continue
            }
            let c = tree.appendCopy(of: o, from: old, parent: p, keepStats: true)
            let lo = Int(old.childOffsets[o]), hi = Int(old.childOffsets[o + 1])
            var k = hi - 1
            while k >= lo { stack.append((Int(old.childIndex[k]), c)); k -= 1 }
        }
    }
}

// MARK: - Entry points shared by DiskScanner and SystemDataBreakdown

enum ScanEngine {
    static let dataVolumePath = "/System/Volumes/Data"

    static func loadFirmlinks() -> [Firmlink] {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return nil }
            return Firmlink(source: String(parts[0]), target: String(parts[1]))
        }
    }

    static func volumeName(of path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    /// Prepares an empty tree for `root` (resolving "/" to the Data volume) and checks the root.
    static func makeTree(root rawRoot: String, config: ScanConfiguration, captureEvents: Bool) throws -> ScanTree {
        let root = ScanTree.normalize((rawRoot as NSString).expandingTildeInPath)
        var rootPath = root
        var scanPath: String
        var rootName: String
        var firmlinks: [Firmlink] = []
        var isDir: ObjCBool = false
        if root == "/" && FileManager.default.fileExists(atPath: dataVolumePath, isDirectory: &isDir) && isDir.boolValue {
            scanPath = dataVolumePath
            rootName = volumeName(of: "/") ?? "Macintosh HD"
            firmlinks = loadFirmlinks()
            rootPath = "/"
        } else {
            guard let real = realpath(root, nil) else {
                if errno == EACCES || errno == EPERM { throw ScanError.rootUnreadable(root, errno: errno) }
                throw ScanError.rootNotFound(root)
            }
            scanPath = String(cString: real)
            free(real)
            rootName = root == "/" ? (volumeName(of: "/") ?? "Macintosh HD") : (root as NSString).lastPathComponent
        }
        var st = stat()
        guard stat(scanPath, &st) == 0 else {
            if errno == EACCES || errno == EPERM { throw ScanError.rootUnreadable(root, errno: errno) }
            throw ScanError.rootNotFound(root)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ScanError.rootNotADirectory(root) }
        let eventID = captureEvents ? FSEventsReplay.currentEventID() : 0
        let uuid = captureEvents ? FSEventsReplay.uuid(forDevice: st.st_dev) : nil
        return ScanTree(rootPath: rootPath, scanPath: scanPath, rootName: rootName, deviceID: st.st_dev,
                        lastEventID: eventID, eventsUUID: uuid, largeFileThreshold: config.largeFileThreshold,
                        firmlinks: firmlinks)
    }

    static func fullScan(root: String, exclusions: [String], config: ScanConfiguration, captureEvents: Bool = true,
                         progress: (ScanProgress) -> Void) async throws -> (ScanTree, directoriesRead: Int) {
        let tree = try makeTree(root: root, config: config, captureEvents: captureEvents)
        let walk = Walk(tree: tree, old: nil, config: config, exclusions: Exclusions.resolve(exclusions, for: tree))
        walk.seedFullScan()
        try await walk.run(progress: progress)
        if walk.tree.flags[0] & ScanTree.flagUnreadable != 0, walk.tree.nodeCount == 1 {
            // Root could not be listed at all: surface it as an error rather than an empty tree.
            var code: Int32 = EPERM
            let fd = open(walk.tree.scanPath, O_RDONLY | O_DIRECTORY)
            if fd >= 0 { close(fd) } else { code = errno }
            throw ScanError.rootUnreadable(root, errno: code)
        }
        walk.tree.scannedAt = Date()
        walk.tree.finalize()
        progress(walk.currentProgress(path: walk.tree.scanPath))
        return (walk.tree, walk.directoriesRead)
    }
}
