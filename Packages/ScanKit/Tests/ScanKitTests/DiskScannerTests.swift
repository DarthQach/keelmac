import Darwin
import Foundation
import Testing
@testable import ScanKit

@Suite("DiskScanner", .serialized)
struct DiskScannerTests {
    static let threshold: Int64 = 200_000

    /// root/
    ///   a/file1 (10 kB), a/file2 (100 kB), a/hard3 → b/hard1
    ///   a/deep/big.bin (300 kB, a large-file node)
    ///   b/hard1 (50 kB), b/hard2 → b/hard1
    ///   c/toFile → ../a/file2, c/toUsr → /usr (symlinks, not followed)
    ///   locked/ (chmod 000) with secret (40 kB)
    ///   skip/ excluded, with junk (80 kB)
    func makeFixture() throws -> Fixture {
        let f = try Fixture()
        try f.file("a/file1", bytes: 10_000)
        try f.file("a/file2", bytes: 100_000)
        try f.file("a/deep/big.bin", bytes: 300_000)
        try f.file("b/hard1", bytes: 50_000)
        try f.hardLink("b/hard2", to: "b/hard1")
        try f.hardLink("a/hard3", to: "b/hard1")
        try f.dir("c")
        try f.symlink("c/toFile", to: "../a/file2")
        try f.symlink("c/toUsr", to: "/usr")
        try f.file("locked/secret", bytes: 40_000)
        try f.file("skip/junk", bytes: 80_000)
        return f
    }

    func scanner(_ configure: (inout ScanConfiguration) -> Void = { _ in }) -> DiskScanner {
        var c = ScanConfiguration(largeFileThreshold: Self.threshold)
        configure(&c)
        return DiskScanner(configuration: c)
    }

    @Test func sizesCountsHardLinksSymlinksAndExclusions() async throws {
        let f = try makeFixture()
        defer { f.remove() }
        let (tree, progress) = try await runScan(scanner(), root: f.root, exclusions: [f.path("skip")])

        let symlinks = f.allocated("c/toFile") + f.allocated("c/toUsr")
        let expected = f.allocated("a/file1") + f.allocated("a/file2") + f.allocated("a/deep/big.bin")
            + f.allocated("b/hard1") + symlinks + f.allocated("locked/secret")
        #expect(tree.totalBytesOnDisk == expected)
        // file1, file2, big.bin, hard1 (once for three links), two symlinks, secret.
        #expect(tree.totalFileCount == 7)

        let b = try #require(tree.lookup(path: f.path("b")))
        let a = try #require(tree.lookup(path: f.path("a")))
        // The hard link is counted in exactly one of the two folders.
        #expect(tree.info(a).fileCount + tree.info(b).fileCount == 4) // file1, file2, big.bin, hard link once
        #expect(tree.info(a).bytes + tree.info(b).bytes ==
                f.allocated("a/file1") + f.allocated("a/file2") + f.allocated("a/deep/big.bin") + f.allocated("b/hard1"))

        // Symlinks are counted as tiny files, never followed.
        let c = try #require(tree.lookup(path: f.path("c")))
        #expect(tree.info(c).bytes == symlinks)
        #expect(tree.info(c).fileCount == 2)
        #expect(tree.children(of: c).isEmpty)

        // Large file kept as a node; small files are not.
        let big = try #require(tree.lookup(path: f.path("a/deep/big.bin")))
        #expect(!tree.isDirectory(big))
        #expect(tree.bytes(of: big) == f.allocated("a/deep/big.bin"))
        #expect(tree.lookup(path: f.path("a/file1")) == nil)

        // Exclusion honoured.
        #expect(tree.lookup(path: f.path("skip")) == nil)
        #expect(!progress.isEmpty)
    }

    @Test func unreadableFolderIsRecorded() async throws {
        let f = try makeFixture()
        defer { f.remove() }
        chmod(f.path("locked"), 0o000)
        let (tree, progress) = try await runScan(scanner(), root: f.root)
        let locked = try #require(tree.lookup(path: f.path("locked")))
        #expect(tree.info(locked).isUnreadable)
        #expect(tree.bytes(of: locked) == 0)
        #expect(tree.unreadable.count == 1)
        #expect(tree.unreadable.first.map { $0.hasSuffix("/locked") } == true)
        #expect(tree.unreadable.first.flatMap { tree.lookup(path: $0) } == locked)
        #expect(progress.last?.unreadableCount == 1)
    }

    @Test func treeQueries() async throws {
        let f = try makeFixture()
        defer { f.remove() }
        let (tree, _) = try await runScan(scanner(), root: f.root)
        let kids = tree.children(of: tree.root)
        #expect(kids.count == 5) // a, b, c, locked, skip
        let sizes = kids.map { tree.bytes(of: $0) }
        #expect(sizes == sizes.sorted(by: >))
        #expect(tree.name(of: kids[0]) == "a")

        let deep = try #require(tree.lookup(path: f.path("a/deep")))
        let a = try #require(tree.lookup(path: f.path("a")))
        #expect(tree.parent(of: deep) == a)
        #expect(tree.parent(of: tree.root) == nil)
        #expect(tree.ancestors(of: deep) == [tree.root, a])
        #expect(tree.info(deep).path == f.path("a/deep"))
        // Real (symlink-resolved) path form works too.
        #expect(tree.lookup(path: tree.realPath(ofIndex: deep.index)) == deep)
        #expect(tree.lookup(path: f.path("a/DEEP")) == deep) // APFS is case-insensitive
        #expect(tree.lookup(path: f.path("nope")) == nil)
        #expect(tree.lookup(path: "/elsewhere") == nil)
        #expect(tree.lookup(path: f.root + "/") == tree.root)
    }

    @Test func modifiedDateIsNewestInSubtree() async throws {
        let f = try makeFixture()
        defer { f.remove() }
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        for rel in ["a/file1", "a/file2", "a/hard3", "a/deep/big.bin", "a/deep", "a"] { try f.setDate(rel, modified: old) }
        try f.setDate("a/deep/big.bin", modified: new)
        try f.setDate("a/deep", modified: old)
        let (tree, _) = try await runScan(scanner(), root: f.root)
        let a = try #require(tree.lookup(path: f.path("a")))
        #expect(tree.info(a).modified == new)
    }

    @Test func cancellationStopsPromptly() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for i in 0..<300 { try f.dir("d\(i)/inner") }
        let s = scanner { $0.concurrency = 2; $0.testingDirectoryDelay = 0.05 } // ≈ 15 s if not cancelled
        let root = f.root
        let started = Date()
        let consumer = Task { () -> Bool in
            var finished = false
            do {
                for try await event in await s.scan(root: root) {
                    if case .finished = event { finished = true }
                }
            } catch {}
            return finished
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        consumer.cancel()
        let finished = await consumer.value
        #expect(!finished)
        #expect(Date().timeIntervalSince(started) < 3)

        // Cancelling the scan task directly surfaces CancellationError.
        let config = ScanConfiguration(largeFileThreshold: Self.threshold, concurrency: 2)
        var slow = config
        slow.testingDirectoryDelay = 0.05
        let direct = Task { try await ScanEngine.fullScan(root: root, exclusions: [], config: slow) { _ in }.0.nodeCount }
        try await Task.sleep(nanoseconds: 200_000_000)
        direct.cancel()
        await #expect(throws: CancellationError.self) { _ = try await direct.value }
    }

    @Test func progressIsThrottled() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for i in 0..<60 { try f.dir("d\(i)") }
        let s = scanner { $0.concurrency = 1; $0.testingDirectoryDelay = 0.02 } // ≈ 1.2 s
        let (_, progress) = try await runScan(s, root: f.root)
        let elapsed = try #require(progress.last?.elapsed)
        // ≤ 10 per second, plus the final event.
        #expect(Double(progress.count) <= elapsed * 10 + 2)
        #expect(progress.count >= 3)
    }

    @Test func missingRootThrows() async throws {
        await #expect(throws: ScanError.self) {
            _ = try await runScan(DiskScanner(), root: "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func startupDiskMapsToDataVolume() throws {
        let tree = try ScanEngine.makeTree(root: "/", config: ScanConfiguration(), captureEvents: true)
        #expect(tree.rootPath == "/")
        #expect(tree.scanPath == "/System/Volumes/Data")
        #expect(!tree.rootName.isEmpty)
        #expect(tree.firmlinks.contains(Firmlink(source: "/Users", target: "Users")))
        #expect(tree.lastEventID > 0)
        #expect(tree.relativePath(for: "/Users/someone") == "Users/someone")
        #expect(tree.relativePath(for: "/System/Volumes/Data/Users/someone") == "Users/someone")
        #expect(tree.relativePath(for: "/System/Library/Caches/x") == "System/Library/Caches/x")
        #expect(tree.relativePath(for: "/bin/ls") == nil) // System volume, not scanned
    }

    @Test func rescanFolderRereadsOnlyThatSubtree() async throws {
        let f = try makeFixture()
        defer { f.remove() }
        let s = scanner()
        let (tree, _) = try await runScan(s, root: f.root)
        try f.file("b/new.bin", bytes: 250_000)
        try f.file("a/unseen", bytes: 30_000) // outside the rescanned folder: must stay unseen

        let updated = try await collect(await s.rescan(tree, folder: f.path("b")))
        let summary = try #require(await s.lastRescan)
        #expect(summary.mode == .folder)
        #expect(summary.directoriesRead == 1)
        let b = try #require(updated.lookup(path: f.path("b")))
        #expect(updated.bytes(of: b) == f.allocated("b/hard1") + f.allocated("b/new.bin")
                || updated.bytes(of: b) == f.allocated("b/new.bin")) // hard link may have been attributed to a/
        #expect(updated.lookup(path: f.path("b/new.bin")) != nil)
        let a = try #require(updated.lookup(path: f.path("a")))
        #expect(updated.bytes(of: a) == tree.bytes(of: tree.lookup(path: f.path("a"))!))
        #expect(updated.totalBytesOnDisk == tree.totalBytesOnDisk + updated.bytes(of: b) - tree.bytes(of: tree.lookup(path: f.path("b"))!))
        #expect(updated.lastEventID == tree.lastEventID)
    }

    @Test func incrementalRescanReadsOnlyChangedFolder() async throws {
        let f = try makeFixture()
        defer { f.remove() }
        // Let fseventsd assign ids to the fixture's own creation events before the scan captures its event id.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let s = scanner()
        let (tree, _) = try await runScan(s, root: f.root)
        try f.file("a/deep/added.bin", bytes: 220_000)

        // fseventsd records asynchronously; replay from the original tree until the change shows up.
        var updated: ScanTree?
        var summary: RescanSummary?
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            updated = try await collect(await s.rescan(tree))
            summary = await s.lastRescan
            if summary?.changedDirectories.isEmpty == false { break }
        }
        let result = try #require(updated)
        let info = try #require(summary)
        #expect(info.mode == .incremental)
        #expect(info.changedDirectories.contains(f.path("a/deep")))
        #expect(!info.changedDirectories.contains(f.path("b")))
        #expect(info.directoriesRead == info.changedDirectories.count) // only changed folders are listed
        #expect(info.directoriesRead < 7)

        let deep = try #require(result.lookup(path: f.path("a/deep")))
        #expect(result.bytes(of: deep) == f.allocated("a/deep/big.bin") + f.allocated("a/deep/added.bin"))
        #expect(result.lookup(path: f.path("a/deep/added.bin")) != nil)
        // Ancestors re-aggregated, siblings untouched.
        #expect(result.totalBytesOnDisk == tree.totalBytesOnDisk + f.allocated("a/deep/added.bin"))
        let b = try #require(result.lookup(path: f.path("b")))
        #expect(result.bytes(of: b) == tree.bytes(of: tree.lookup(path: f.path("b"))!))
        #expect(result.nodeCount == tree.nodeCount + 1)
        #expect(result.lastEventID > tree.lastEventID)
    }

    @Test func rescanWithoutHistoryFallsBackToFullScan() async throws {
        let f = try makeFixture()
        defer { f.remove() }
        let s = scanner()
        var (tree, _) = try await runScan(s, root: f.root)
        tree.lastEventID = 0
        let updated = try await collect(await s.rescan(tree))
        #expect(await s.lastRescan?.mode == .full(.noEventHistory))
        #expect(updated.totalBytesOnDisk == tree.totalBytesOnDisk)
    }
}
