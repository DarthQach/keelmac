import CryptoKit
import Foundation
import SafetyKit
import Testing
@testable import DuplicatesKit

/// A throwaway fake home in the temp directory; the finder's PathGuard treats it as the user's home.
final class Fixture {
    let root: URL
    let pathGuard: PathGuard

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("InsightsKit-dups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pathGuard = PathGuard(home: root.path, userName: "tester", uid: 501)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    @discardableResult
    func write(_ relative: String, _ data: Data, modified: Date? = nil) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func finder() -> DuplicateFinder { DuplicateFinder(pathGuard: pathGuard) }

    func find(minBytes: Int64 = 1) async throws -> [DuplicateGroup] {
        try await finder().find(roots: [root.path], minBytes: minBytes, progress: { _ in })
    }
}

func bytes(_ count: Int, _ seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) &+ seed })
}

func names(_ group: DuplicateGroup) -> Set<String> {
    Set(group.files.map { URL(fileURLWithPath: $0.path).lastPathComponent })
}

@Suite("DuplicateFinder")
struct DuplicateFinderTests {
    @Test("Same size, different content is not a duplicate")
    func sameSizeDifferentContent() async throws {
        let fx = try Fixture()
        try fx.write("Documents/a.bin", bytes(5000, 1))
        try fx.write("Documents/b.bin", bytes(5000, 2))
        #expect(try await fx.find().isEmpty)
    }

    @Test("Three identical files form one group keyed by the full SHA-256")
    func threeIdentical() async throws {
        let fx = try Fixture()
        let content = bytes(200_000, 7)
        try fx.write("Documents/one.dat", content)
        try fx.write("Downloads/two.dat", content)
        try fx.write("Desktop/deep/three.dat", content)
        try fx.write("Documents/unique.dat", bytes(200_000, 9))
        let groups = try await fx.find()
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(names(group) == ["one.dat", "two.dat", "three.dat"])
        #expect(group.bytesEach == 200_000)
        #expect(group.wastedBytes == 400_000)
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        #expect(group.id == expected)
        #expect(group.files.map(\.path) == group.files.map(\.path).sorted())
    }

    @Test("Identical heads with different tails are not grouped")
    func headsMatchTailsDiffer() async throws {
        let fx = try Fixture()
        var a = bytes(300_000, 3)
        var b = a
        a[a.count - 1] = 0x01
        b[b.count - 1] = 0x02
        try fx.write("Documents/a.bin", a)
        try fx.write("Documents/b.bin", b)
        #expect(try await fx.find().isEmpty)
    }

    @Test("Matching heads and tails but a different middle is caught by the full hash")
    func middleDiffers() async throws {
        let fx = try Fixture()
        var a = bytes(3_000_000, 4)
        var b = a
        a[1_500_000] = 0xAA
        b[1_500_000] = 0xBB
        try fx.write("Documents/a.bin", a)
        try fx.write("Documents/b.bin", b)
        #expect(try await fx.find().isEmpty)
    }

    @Test("Hard links to one inode are not duplicates of each other")
    func hardLinks() async throws {
        let fx = try Fixture()
        let content = bytes(10_000, 5)
        let original = try fx.write("Documents/original.txt", content)
        try FileManager.default.linkItem(at: original, to: fx.url("Documents/link.txt"))
        #expect(try await fx.find().isEmpty)

        try fx.write("Downloads/copy.txt", content)
        let groups = try await fx.find()
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.files.count == 2)
        // The smallest path of the linked pair is kept, plus the real copy.
        #expect(names(group) == ["link.txt", "copy.txt"])
    }

    @Test("Packages are opaque: nothing inside .app, .bundle or .photoslibrary is listed")
    func packagesNotDescended() async throws {
        let fx = try Fixture()
        let content = bytes(4096, 6)
        try fx.write("Documents/a.dat", content)
        try fx.write("Documents/b.dat", content)
        try fx.write("Applications/Thing.app/Contents/Resources/c.dat", content)
        try fx.write("Documents/Plug.bundle/Contents/d.dat", content)
        try fx.write("Pictures/Trip.photoslibrary/originals/e.dat", content)
        let groups = try await fx.find()
        #expect(groups.count == 1)
        #expect(names(try #require(groups.first)) == ["a.dat", "b.dat"])
    }

    @Test("Protected paths, hidden files, symlinks and empty files are skipped")
    func skippedItems() async throws {
        let fx = try Fixture()
        let content = bytes(4096, 8)
        try fx.write("Documents/a.dat", content)
        try fx.write("Documents/b.dat", content)
        try fx.write("Library/Mobile Documents/com~apple~CloudDocs/icloud.dat", content)
        try fx.write("Library/Mail/V10/mail.dat", content)
        try fx.write("Documents/.hidden.dat", content)
        try fx.write(".config/dot.dat", content)
        try FileManager.default.createSymbolicLink(at: fx.url("Documents/alias.dat"), withDestinationURL: fx.url("Documents/a.dat"))
        try fx.write("Documents/empty1", Data())
        try fx.write("Documents/empty2", Data())

        let result = try await fx.finder().search(roots: [fx.root.path], minBytes: 1, progress: { _ in })
        #expect(result.groups.count == 1)
        #expect(names(try #require(result.groups.first)) == ["a.dat", "b.dat"])
        #expect(result.protectedSkipped >= 2)
    }

    @Test("A root PathGuard refuses is not walked at all")
    func protectedRoot() async throws {
        let fx = try Fixture()
        let content = bytes(2048, 10)
        try fx.write("Library/Mobile Documents/x.dat", content)
        try fx.write("Library/Mobile Documents/y.dat", content)
        let groups = try await fx.finder().find(roots: [fx.url("Library/Mobile Documents").path], minBytes: 1, progress: { _ in })
        #expect(groups.isEmpty)
    }

    @Test("Files below minBytes are ignored; overlapping roots don't double count")
    func minBytesAndOverlap() async throws {
        let fx = try Fixture()
        try fx.write("Documents/s1", bytes(100, 1))
        try fx.write("Documents/s2", bytes(100, 1))
        try fx.write("Documents/big1", bytes(5000, 2))
        try fx.write("Documents/sub/big2", bytes(5000, 2))
        let finder = fx.finder()
        let groups = try await finder.find(roots: [fx.url("Documents").path, fx.url("Documents/sub").path],
                                           minBytes: 1000, progress: { _ in })
        #expect(groups.count == 1)
        #expect(names(try #require(groups.first)) == ["big1", "big2"])
    }

    @Test("Progress walks the stages in order with consistent counts")
    func progressStages() async throws {
        let fx = try Fixture()
        let content = bytes(70_000, 11)
        try fx.write("Documents/a", content)
        try fx.write("Documents/b", content)
        try fx.write("Documents/c", bytes(70_000, 12))
        let recorder = ProgressRecorder()
        _ = try await fx.finder().find(roots: [fx.root.path], minBytes: 1, progress: { recorder.add($0) })
        let events = recorder.events
        let stages = events.map(\.stage)
        let order = DuplicateProgress.Stage.allCases
        #expect(stages.map { order.firstIndex(of: $0)! } == stages.map { order.firstIndex(of: $0)! }.sorted())
        #expect(Set(stages) == Set(order))
        #expect(events.last == DuplicateProgress(stage: .hashingFull, done: 2, total: 2))
        #expect(events.contains(DuplicateProgress(stage: .hashingHeads, done: 3, total: 3)))
    }

    @Test("Cancelling the task stops the search with CancellationError")
    func cancellation() async throws {
        let fx = try Fixture()
        let content = bytes(50_000, 13)
        for i in 0..<6 { try fx.write("Documents/f\(i)", content) }
        let finder = fx.finder()
        await #expect(throws: CancellationError.self) {
            _ = try await finder.find(roots: [fx.root.path], minBytes: 1) { progress in
                // Progress is reported on the searching task; cancel it once hashing starts.
                if progress.stage == .hashingHeads { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        // An already-cancelled task never gets past listing.
        let task = Task { try await finder.find(roots: [fx.root.path], minBytes: 1, progress: { _ in }) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DuplicateProgress] = []
    func add(_ p: DuplicateProgress) { lock.withLock { storage.append(p) } }
    var events: [DuplicateProgress] { lock.withLock { storage } }
}
