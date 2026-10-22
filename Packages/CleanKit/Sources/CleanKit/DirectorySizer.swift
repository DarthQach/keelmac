import Darwin
import Foundation

/// Size of one file or folder tree.
public struct SizeInfo: Sendable, Equatable {
    /// Allocated bytes (what removing it frees). Hard links are counted once.
    public var bytes: Int64 = 0
    public var fileCount: Int = 0
    /// Newest modification date of the item and everything inside it.
    public var newestModified: Date?
    /// Folders that couldn't be read.
    public var unreadable: Int = 0
    /// The item's own lstat information.
    public var ownModified: Date?
    public var isDirectory = false
    public var exists = false
}

/// Measures allocated sizes with `getattrlistbulk` on a pool of threads that share one work queue,
/// so many roots and a single deep root are measured in parallel. Never follows symlinks and never
/// crosses into another mounted volume.
public enum DirectorySizer {
    public static func size(_ paths: [String], threads: Int = defaultThreads) async -> [String: SizeInfo] {
        let unique = Array(Set(paths))
        if unique.isEmpty { return [:] }
        return await withCheckedContinuation { (c: CheckedContinuation<[String: SizeInfo], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: sizeBlocking(unique, threads: threads))
            }
        }
    }

    public static func size(_ path: String) async -> SizeInfo {
        await size([path])[path] ?? SizeInfo()
    }

    public static var defaultThreads: Int { min(16, max(4, ProcessInfo.processInfo.activeProcessorCount)) }

    /// Synchronous version (blocks the calling thread).
    public static func sizeBlocking(_ paths: [String], threads: Int = defaultThreads) -> [String: SizeInfo] {
        var infos = [SizeInfo](repeating: SizeInfo(), count: paths.count)
        var dirRoots: [Int] = []
        for (i, path) in paths.enumerated() {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            infos[i].exists = true
            let mtime = date(st.st_mtimespec)
            infos[i].ownModified = mtime
            infos[i].newestModified = mtime
            if (st.st_mode & S_IFMT) == S_IFDIR {
                infos[i].isDirectory = true
                dirRoots.append(i)
            } else {
                infos[i].bytes = Int64(st.st_blocks) * 512
                infos[i].fileCount = 1
            }
        }
        if !dirRoots.isEmpty {
            let pool = SizerPool(roots: dirRoots.map { (paths[$0], $0) }, rootCount: paths.count)
            let totals = pool.run(threads: threads)
            for i in dirRoots {
                infos[i].bytes = totals[i].bytes
                infos[i].fileCount = totals[i].files
                infos[i].unreadable = totals[i].unreadable
                if totals[i].newest > 0 {
                    let newest = Date(timeIntervalSince1970: totals[i].newest)
                    if newest > (infos[i].newestModified ?? .distantPast) { infos[i].newestModified = newest }
                }
            }
        }
        var out: [String: SizeInfo] = [:]
        for (i, p) in paths.enumerated() { out[p] = infos[i] }
        return out
    }

    static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }
}

struct SizerTotals {
    var bytes: Int64 = 0
    var files = 0
    var unreadable = 0
    var newest: TimeInterval = 0
}

/// A shared stack of directories; workers pop one, list it with getattrlistbulk, push its subfolders.
private final class SizerPool: @unchecked Sendable {
    private struct Job { let path: String; let root: Int }

    private let cond = NSCondition()
    private var stack: [Job]
    private var active = 0
    private let rootCount: Int
    private var merged: [SizerTotals]
    private var seenLinks = Set<UInt64>()
    private let linkLock = NSLock()

    // getattrlistbulk constants (sys/attr.h).
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let dirMountStatus: UInt32 = 0x0000_0004
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let mntPoint: UInt32 = 0x0000_0001
    private static let vREG: UInt32 = 1, vDIR: UInt32 = 2

    init(roots: [(String, Int)], rootCount: Int) {
        stack = roots.map { Job(path: $0.0, root: $0.1) }
        self.rootCount = rootCount
        merged = [SizerTotals](repeating: SizerTotals(), count: rootCount)
    }

    func run(threads: Int) -> [SizerTotals] {
        let group = DispatchGroup()
        for _ in 0..<max(1, threads) {
            group.enter()
            Thread.detachNewThread { [self] in
                worker()
                group.leave()
            }
        }
        group.wait()
        return merged
    }

    private func next() -> Job? {
        cond.lock(); defer { cond.unlock() }
        while stack.isEmpty && active > 0 { cond.wait() }
        guard let job = stack.popLast() else { return nil }
        active += 1
        return job
    }

    private func finish(pushing children: [Job]) {
        cond.lock()
        stack.append(contentsOf: children)
        active -= 1
        if !children.isEmpty || (stack.isEmpty && active == 0) { cond.broadcast() }
        cond.unlock()
    }

    private func firstSighting(of fileID: UInt64) -> Bool {
        linkLock.lock(); defer { linkLock.unlock() }
        return seenLinks.insert(fileID).inserted
    }

    private func worker() {
        var local = [Int: SizerTotals]()
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = SizerPool.cmnReturnedAttrs | SizerPool.cmnName | SizerPool.cmnError | SizerPool.cmnObjType
            | SizerPool.cmnModTime | SizerPool.cmnFileID
        attrs.dirattr = SizerPool.dirMountStatus
        attrs.fileattr = SizerPool.fileLinkCount | SizerPool.fileAllocSize

        while let job = next() {
            var totals = local[job.root] ?? SizerTotals()
            var children: [Job] = []
            list(job, buffer: buffer, size: bufferSize, attrs: &attrs, totals: &totals, children: &children)
            local[job.root] = totals
            finish(pushing: children)
        }
        cond.lock()
        for (root, t) in local {
            merged[root].bytes += t.bytes
            merged[root].files += t.files
            merged[root].unreadable += t.unreadable
            merged[root].newest = max(merged[root].newest, t.newest)
        }
        cond.unlock()
    }

    private func list(_ job: Job, buffer: UnsafeMutableRawPointer, size: Int, attrs: inout attrlist,
                      totals: inout SizerTotals, children: inout [Job]) {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { totals.unreadable += 1; return }
        defer { close(fd) }
        let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, size, 0)
            if count < 0 { totals.unreadable += 1; return }
            if count == 0 { return }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                if returned.commonattr & SizerPool.cmnError != 0 {
                    let err = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if err != 0 { totals.unreadable += 1; continue }
                }
                var name = ""
                if returned.commonattr & SizerPool.cmnName != 0 {
                    let offset = Int(field.loadUnaligned(as: Int32.self))
                    name = String(cString: (field + offset).assumingMemoryBound(to: CChar.self))
                    field += MemoryLayout<attrreference_t>.size
                }
                var type: UInt32 = 0
                if returned.commonattr & SizerPool.cmnObjType != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.commonattr & SizerPool.cmnModTime != 0 {
                    let ts = field.loadUnaligned(as: timespec.self)
                    field += MemoryLayout<timespec>.size
                    let t = TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9
                    if t > totals.newest { totals.newest = t }
                }
                var fileID: UInt64 = 0
                if returned.commonattr & SizerPool.cmnFileID != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if type == SizerPool.vDIR {
                    var mountPoint = false
                    if returned.dirattr & SizerPool.dirMountStatus != 0 {
                        mountPoint = field.loadUnaligned(as: UInt32.self) & SizerPool.mntPoint != 0
                        field += 4
                    }
                    if !mountPoint && !name.isEmpty { children.append(Job(path: prefix + name, root: job.root)) }
                    continue
                }
                var links: UInt32 = 1
                if returned.fileattr & SizerPool.fileLinkCount != 0 {
                    links = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var alloc: Int64 = 0
                if returned.fileattr & SizerPool.fileAllocSize != 0 {
                    alloc = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                if type == SizerPool.vREG && links > 1 && !firstSighting(of: fileID) { continue }
                totals.bytes += alloc
                totals.files += 1
            }
        }
    }
}
