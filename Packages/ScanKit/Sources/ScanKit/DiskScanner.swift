import Foundation

/// Scans a folder or the startup disk with `getattrlistbulk`, read-only.
///
/// Every method returns a stream that yields throttled `.progress` events (at most 10 per second) and one
/// `.finished(tree)`. Cancelling the consuming task (or dropping the stream) stops the walk promptly; the
/// stream then ends with `CancellationError`.
public actor DiskScanner {
    public let configuration: ScanConfiguration
    /// How the most recent rescan was carried out.
    public private(set) var lastRescan: RescanSummary?

    public init() { self.configuration = ScanConfiguration() }
    public init(configuration: ScanConfiguration) { self.configuration = configuration }

    /// Full scan. A root of "/" scans the Data volume and presents it as the startup disk.
    public func scan(root: String, exclusions: [String] = []) -> AsyncThrowingStream<ScanEvent, Error> {
        let config = configuration
        return Self.stream { emit in
            try await ScanEngine.fullScan(root: root, exclusions: exclusions, config: config, progress: emit).0
        }
    }

    /// Replays FSEvents since `tree.lastEventID` and re-reads only the folders that changed.
    /// Falls back to a full scan when history is unavailable or FSEvents asks for a full rescan.
    public func rescan(_ tree: ScanTree, exclusions: [String] = []) -> AsyncThrowingStream<ScanEvent, Error> {
        let config = configuration
        return Self.stream { [weak self] emit in
            let started = Date()
            let (newTree, summary) = try await Self.incremental(tree, exclusions: exclusions, config: config, progress: emit)
            var s = summary
            s.elapsed = Date().timeIntervalSince(started)
            await self?.record(s)
            return newTree
        }
    }

    /// "Rescan this folder": re-reads the whole subtree of `folder` and re-aggregates its ancestors.
    public func rescan(_ tree: ScanTree, folder: String, exclusions: [String] = []) -> AsyncThrowingStream<ScanEvent, Error> {
        let config = configuration
        return Self.stream { [weak self] emit in
            let started = Date()
            guard let node = tree.nearestNode(for: folder), tree.isDirectory(node) || tree.parent(of: node) != nil else {
                let (t, read) = try await ScanEngine.fullScan(root: tree.rootPath, exclusions: exclusions, config: config, progress: emit)
                await self?.record(RescanSummary(mode: .full(.pathOutsideTree), changedDirectories: [], directoriesRead: read,
                                                 elapsed: Date().timeIntervalSince(started)))
                return t
            }
            let dir = tree.isDirectory(node) ? node : tree.parent(of: node)!
            let walk = Walk(tree: tree.emptyCopy(), old: tree, config: config,
                            exclusions: Exclusions.resolve(exclusions, for: tree))
            walk.fullRescan = [dir.raw]
            walk.dropped = Self.excludedNodes(in: tree, exclusions: exclusions)
            walk.seedFromOld()
            try await walk.run(progress: emit)
            walk.tree.scannedAt = Date()
            walk.tree.finalize()  // keeps the old lastEventID: other folders may have changed meanwhile
            emit(walk.currentProgress(path: tree.realPath(ofIndex: dir.index)))
            await self?.record(RescanSummary(mode: .folder, changedDirectories: [tree.path(of: dir)],
                                             directoriesRead: walk.directoriesRead, elapsed: Date().timeIntervalSince(started)))
            return walk.tree
        }
    }

    private func record(_ summary: RescanSummary) { lastRescan = summary }

    // MARK: Internals

    static func incremental(_ tree: ScanTree, exclusions: [String], config: ScanConfiguration,
                            progress: (ScanProgress) -> Void) async throws -> (ScanTree, RescanSummary) {
        func full(_ reason: RescanSummary.FullScanReason) async throws -> (ScanTree, RescanSummary) {
            let (t, read) = try await ScanEngine.fullScan(root: tree.rootPath, exclusions: exclusions, config: config, progress: progress)
            return (t, RescanSummary(mode: .full(reason), changedDirectories: [], directoriesRead: read, elapsed: 0))
        }
        guard tree.lastEventID != 0, tree.nodeCount > 0 else { return try await full(.noEventHistory) }
        var st = stat()
        guard stat(tree.scanPath, &st) == 0, st.st_dev == tree.deviceID else { return try await full(.rootChanged) }
        if let uuid = tree.eventsUUID, FSEventsReplay.uuid(forDevice: st.st_dev) != uuid { return try await full(.noEventHistory) }

        let newEventID = FSEventsReplay.currentEventID()
        let replay = await FSEventsReplay.replay(path: tree.scanPath, since: tree.lastEventID)
        try Task.checkCancellation()
        if let reason = replay.fullScanReason { return try await full(reason) }

        // Map changed paths to the folders to re-list.
        var changed = Set<Int32>()
        for p in replay.paths {
            guard tree.relativePath(for: p) != nil else { continue } // outside the scanned root
            guard let node = tree.nearestNode(for: p) else { return try await full(.pathOutsideTree) }
            let dir = tree.isDirectory(node) ? node : (tree.parent(of: node) ?? tree.root)
            changed.insert(dir.raw)
        }
        let walk = Walk(tree: tree.emptyCopy(), old: tree, config: config, exclusions: Exclusions.resolve(exclusions, for: tree))
        walk.changed = changed
        walk.dropped = excludedNodes(in: tree, exclusions: exclusions)
        walk.seedFromOld()
        try await walk.run(progress: progress)
        walk.tree.lastEventID = newEventID
        walk.tree.scannedAt = Date()
        walk.tree.finalize()
        progress(walk.currentProgress(path: tree.scanPath))
        let summary = RescanSummary(mode: .incremental, changedDirectories: changed.sorted().map { tree.path(of: NodeID(raw: $0)) },
                                    directoriesRead: walk.directoriesRead, elapsed: 0)
        return (walk.tree, summary)
    }

    /// Old nodes that new exclusions now cover.
    static func excludedNodes(in tree: ScanTree, exclusions: [String]) -> Set<Int32> {
        var out = Set<Int32>()
        for e in exclusions {
            if let id = tree.lookup(path: (e as NSString).expandingTildeInPath), id != tree.root { out.insert(id.raw) }
        }
        return out
    }

    private static func stream(_ body: @escaping @Sendable (_ emit: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanTree)
        -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let tree = try await body { continuation.yield(.progress($0)) }
                    continuation.yield(.finished(tree))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
