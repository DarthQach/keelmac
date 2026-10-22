import Foundation
import Testing
@testable import ScanKit

@Suite("ScanTree and ScanCache")
struct TreeAndCacheTests {
    let d1 = Date(timeIntervalSince1970: 1_600_000_000)
    let d2 = Date(timeIntervalSince1970: 1_700_000_000)

    func sample() -> ScanTree {
        makeTree([
            ("small", true, 10, 2, d1),
            ("big", true, 1000, 5, d1),
            ("big/inner", true, 500, 1, d2),
            ("mid", true, 300, 3, d1),
            ("movie.mov", false, 700, 1, d1),
        ])
    }

    @Test func aggregationAndOrdering() {
        let t = sample()
        #expect(t.totalBytesOnDisk == 10 + 1000 + 500 + 300 + 700)
        #expect(t.totalFileCount == 2 + 5 + 1 + 3 + 1)
        let kids = t.children(of: t.root).map { t.name(of: $0) }
        #expect(kids == ["big", "movie.mov", "mid", "small"])
        let big = t.lookup(path: "/R/big")!
        #expect(t.bytes(of: big) == 1500)
        #expect(t.info(big).modified == d2)
        #expect(t.info(t.root).modified == d2)
        #expect(t.smallFilesBytes(of: t.root) == 0) // the movie's bytes are the root's only own bytes
        #expect(t.largeFileNodes.map { t.name(of: $0) } == ["movie.mov"])
        let movie = t.lookup(path: "/R/movie.mov")!
        #expect(t.info(movie).fileCount == 1)
        #expect(!t.info(movie).isDirectory)
    }

    @Test func firmlinkedPaths() {
        let t = makeTree(rootPath: "/", scanPath: "/System/Volumes/Data",
                         firmlinks: [Firmlink(source: "/Users", target: "Users"),
                                     Firmlink(source: "/System/Library/Caches", target: "System/Library/Caches")],
                         [("Users", true, 1, 1, d1), ("Users/me", true, 5, 1, d1), (".Spotlight-V100", true, 3, 1, d1),
                          ("System", true, 0, 0, d1), ("System/Library", true, 0, 0, d1), ("System/Library/Caches", true, 9, 1, d1)])
        let me = t.lookup(path: "/Users/me")!
        #expect(t.info(me).path == "/Users/me")
        #expect(t.lookup(path: "/System/Volumes/Data/Users/me") == me)
        let spot = t.lookup(path: "/System/Volumes/Data/.Spotlight-V100")!
        #expect(t.info(spot).path == "/System/Volumes/Data/.Spotlight-V100")
        let caches = t.lookup(path: "/System/Library/Caches")!
        #expect(t.info(caches).path == "/System/Library/Caches")
        #expect(t.info(t.root).path == "/")
        #expect(t.lookup(path: "/") == t.root)
        #expect(t.lookup(path: "/usr/bin") == nil)
    }

    @Test func cacheRoundTrip() throws {
        let t = sample()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScanKitCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tree.scan")
        try ScanCache.save(t, to: url)
        let loaded = try ScanCache.load(from: url)
        #expect(loaded.nodeCount == t.nodeCount)
        #expect(loaded.rootPath == t.rootPath)
        #expect(loaded.lastEventID == t.lastEventID)
        #expect(loaded.eventsUUID == t.eventsUUID)
        #expect(Int(loaded.scannedAt.timeIntervalSince1970) == Int(t.scannedAt.timeIntervalSince1970))
        for i in 0..<t.nodeCount {
            let id = NodeID(raw: Int32(i))
            #expect(loaded.info(id) == t.info(id))
            #expect(loaded.children(of: id) == t.children(of: id))
        }
        // Codable (JSON / plist) works too and ScanCache.load accepts it; corrupt data is rejected.
        let json = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(ScanTree.self, from: json).totalBytesOnDisk == t.totalBytesOnDisk)
        let plistURL = dir.appendingPathComponent("tree.plist")
        try PropertyListEncoder().encode(t).write(to: plistURL)
        #expect(try ScanCache.load(from: plistURL).children(of: t.root) == t.children(of: t.root))
        let good = try Data(contentsOf: url)
        try good.prefix(good.count - 3).write(to: url)
        #expect(throws: (any Error).self) { _ = try ScanCache.load(from: url) }
        try Data("garbage".utf8).write(to: url)
        #expect(throws: (any Error).self) { _ = try ScanCache.load(from: url) }
    }

    @Test func cacheRoundTripOfRealScan() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for i in 0..<20 { try f.file("d\(i % 4)/sub\(i)/f", bytes: 1000 * (i + 1)) }
        let (tree, _) = try await runScan(DiskScanner(), root: f.root)
        let url = URL(fileURLWithPath: f.path("cache.scan"))
        try ScanCache.save(tree, to: url)
        let loaded = try ScanCache.load(from: url)
        #expect(loaded.totalBytesOnDisk == tree.totalBytesOnDisk)
        #expect(loaded.lookup(path: f.path("d1/sub5")) == tree.lookup(path: f.path("d1/sub5")))
        #expect(loaded.unreadable == tree.unreadable)
    }

    @Test func defaultCacheURLIsStablePerRoot() {
        let base = URL(fileURLWithPath: "/tmp/x")
        #expect(ScanCache.defaultURL(forRoot: "/", appSupport: base) == ScanCache.defaultURL(forRoot: "/", appSupport: base))
        #expect(ScanCache.defaultURL(forRoot: "/", appSupport: base) != ScanCache.defaultURL(forRoot: "/Users", appSupport: base))
    }
}
