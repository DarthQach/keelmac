import Darwin
import Foundation
@testable import ScanKit

/// A temp folder tree for scanner tests. Removed (after restoring permissions) on `remove()`.
final class Fixture {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ScanKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.path
    }

    func path(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    func dir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
    }

    /// Writes `bytes` real (non-sparse) bytes.
    func file(_ rel: String, bytes: Int) throws {
        try dir((rel as NSString).deletingLastPathComponent)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 97) { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        }
        try data.write(to: URL(fileURLWithPath: path(rel)))
    }

    func hardLink(_ rel: String, to target: String) throws {
        guard link(path(target), path(rel)) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    }

    func symlink(_ rel: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(rel), withDestinationPath: destination)
    }

    func setDate(_ rel: String, modified: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path(rel))
    }

    /// Allocated bytes the way `du` counts them.
    func allocated(_ rel: String) -> Int64 {
        var st = stat()
        guard lstat(path(rel), &st) == 0 else { return 0 }
        return Int64(st.st_blocks) * 512
    }

    func remove() {
        // Restore permissions so the tree can be deleted.
        if let e = FileManager.default.enumerator(atPath: root) {
            while let rel = e.nextObject() as? String { chmod(path(rel), 0o755) }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] { chmod(path(name), 0o755) }
        try? FileManager.default.removeItem(atPath: root)
    }
}

func runScan(_ scanner: DiskScanner, root: String, exclusions: [String] = []) async throws -> (ScanTree, [ScanProgress]) {
    var tree: ScanTree?
    var progress: [ScanProgress] = []
    for try await event in await scanner.scan(root: root, exclusions: exclusions) {
        switch event {
        case .progress(let p): progress.append(p)
        case .finished(let t): tree = t
        }
    }
    guard let tree else { throw ScanError.rootNotFound(root) }
    return (tree, progress)
}

func collect(_ stream: AsyncThrowingStream<ScanEvent, Error>) async throws -> ScanTree {
    var tree: ScanTree?
    for try await event in stream { if case .finished(let t) = event { tree = t } }
    guard let tree else { throw ScanError.rootNotFound("stream ended without a tree") }
    return tree
}

/// A hand-built tree: `spec` lists (path relative to root, isDirectory, own bytes, own files, modified).
func makeTree(rootPath: String = "/R", scanPath: String? = nil, firmlinks: [Firmlink] = [],
              _ spec: [(String, Bool, Int64, UInt32, Date)]) -> ScanTree {
    var tree = ScanTree(rootPath: rootPath, scanPath: scanPath ?? rootPath, rootName: "R", deviceID: 1, lastEventID: 42,
                        eventsUUID: "U", largeFileThreshold: 50_000_000, firmlinks: firmlinks)
    tree.appendNode(parent: -1, name: "", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
    var ids: [String: Int32] = ["": 0]
    for (rel, isDir, bytes, files, date) in spec {
        let parentRel = (rel as NSString).deletingLastPathComponent
        let name = (rel as NSString).lastPathComponent
        let parent = ids[parentRel]!
        let mod = UInt32(date.timeIntervalSince1970)
        if !isDir {
            // Like the walker: a large file's bytes are part of its folder's own bytes.
            tree.ownBytes[Int(parent)] += bytes
            tree.ownFiles[Int(parent)] += 1
            tree.ownModified[Int(parent)] = max(tree.ownModified[Int(parent)], mod)
        }
        ids[rel] = tree.appendNode(parent: parent, name: name, isDirectory: isDir,
                                   ownBytes: bytes, ownFiles: isDir ? files : 1, ownModified: mod)
    }
    tree.finalize()
    return tree
}

/// Small deterministic RNG for layout tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
